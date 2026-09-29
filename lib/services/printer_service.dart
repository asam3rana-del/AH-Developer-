import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import '../db/user_repository.dart';
import '../utils/bill_doc.dart';
import '../utils/escpos.dart';
import '../utils/receipt_lines.dart';
import 'receipt_renderer.dart';

class PrinterInfo {
  final String name;
  final String mac;
  const PrinterInfo(this.name, this.mac);
}

/// Kotlin PrinterHelper ka Flutter hissa: Bluetooth (58mm/80mm ESC/POS raster).
/// USB printing Flutter port mein nahi (Android host-mode plugin chahiye) — Settings mein Bluetooth hi hai.
/// Settings keys Kotlin wali hi: printer_name, printer_mac, printer_width, printer_dots.
class PrinterService {
  PrinterService._();
  static final PrinterService instance = PrinterService._();

  final _repo = UserRepository.instance;

  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<PrinterInfo?> selected() async {
    final mac = (await _repo.getSetting('printer_mac')) ?? '';
    if (mac.isEmpty) return null;
    return PrinterInfo((await _repo.getSetting('printer_name')) ?? 'Printer', mac);
  }

  Future<void> savePrinter(String name, String mac) async {
    await _repo.setSetting('printer_name', name);
    await _repo.setSetting('printer_mac', mac);
    await _repo.setSetting('printer_width', '58');
  }

  Future<int> dotsWidth() async =>
      EscPos.normalizeDotsWidth(int.tryParse((await _repo.getSetting('printer_dots')) ?? ''));

  Future<void> saveDotsWidth(int dots) => _repo.setSetting('printer_dots', dots.toString());

  /// Android 12+ par Bluetooth connect/scan runtime permission maangta hai (purane Android par
  /// permission_handler khud granted batata hai). iOS par system prompt pehli connect par aata hai.
  Future<bool> hasPermission() async {
    if (!supported) return false;
    if (Platform.isAndroid) {
      final r = await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
      if (r[Permission.bluetoothConnect]?.isGranted != true) return false;
    }
    return await PrintBluetoothThermal.isPermissionBluetoothGranted;
  }

  Future<bool> bluetoothOn() async => supported && await PrintBluetoothThermal.bluetoothEnabled;

  /// Phone ki Bluetooth settings mein pehle se paired printers.
  Future<List<PrinterInfo>> pairedPrinters() async {
    if (!supported) return [];
    final list = await PrintBluetoothThermal.pairedBluetooths;
    return [for (final b in list) PrinterInfo(b.name.isEmpty ? b.macAdress : b.name, b.macAdress)];
  }

  Future<void> _sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  /// Ek connection par init -> strips (chhote tukron mein, pause ke saath) -> feed+cut.
  Future<bool> _sendSlips(String mac, List<List<({Uint8List bytes, int stripHeight})>> slips) async {
    if (!supported) return false;
    try {
      await PrintBluetoothThermal.disconnect;
      final ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
      if (!ok) return false;
      var allOk = true;
      for (var s = 0; s < slips.length; s++) {
        allOk &= await PrintBluetoothThermal.writeBytes(EscPos.init.toList());
        await _sleep(EscPos.settleDelayMs);
        for (final chunk in slips[s]) {
          final b = chunk.bytes;
          var off = 0;
          while (off < b.length) {
            final end = off + EscPos.btWritePieceBytes > b.length ? b.length : off + EscPos.btWritePieceBytes;
            allOk &= await PrintBluetoothThermal.writeBytes(b.sublist(off, end).toList());
            off = end;
            if (off < b.length) await _sleep(EscPos.btWritePieceGapMs);
          }
          await _sleep(EscPos.interChunkDelayMs(chunk.stripHeight));
        }
        await _sleep(EscPos.settleDelayMs);
        allOk &= await PrintBluetoothThermal.writeBytes(EscPos.feedAndCut.toList());
        if (s < slips.length - 1) await _sleep(EscPos.settleDelayMs);
      }
      return allOk;
    } catch (e) {
      debugPrint('print failed: $e');
      return false;
    } finally {
      try {
        await PrintBluetoothThermal.disconnect;
      } catch (_) {}
    }
  }

  /// Kotlin printReceiptLinesPaged(): bill print, lambi ho to kai slips.
  /// Return null = ok, warna error message.
  Future<String?> printBill(BillDoc doc, {double? netBalance, int maxItemsPerPage = 18}) async {
    final p = await selected();
    if (p == null) return 'Pehle Settings mein printer select karein';
    if (!await hasPermission()) return 'Bluetooth permission dein';
    if (!await bluetoothOn()) return 'Bluetooth on karein';
    final dots = await dotsWidth();
    final pages = paginateReceipt(
      header: receiptHeader(doc),
      items: receiptItems(doc),
      footer: receiptFooter(doc, netBalance: netBalance),
      maxItemsPerPage: maxItemsPerPage,
    );
    final slips = <List<({Uint8List bytes, int stripHeight})>>[];
    for (final lines in pages) {
      final img = await renderReceipt(lines, dotsWidth: dots);
      slips.add(EscPos.rasterChunks(img.rgba, img.width, img.height));
    }
    final ok = await _sendSlips(p.mac, slips);
    return ok ? null : 'Print nahi hua — printer on/paired hai? Dobara koshish karein';
  }

  Future<String?> testPrint({String shopName = ''}) async {
    final p = await selected();
    if (p == null) return 'Pehle printer select karein';
    if (!await hasPermission()) return 'Bluetooth permission dein';
    if (!await bluetoothOn()) return 'Bluetooth on karein';
    final dots = await dotsWidth();
    final lines = <ReceiptLine>[
      RlCenter(shopName.isEmpty ? 'IBTISAAM Kiryana Store' : shopName, bold: true),
      const RlCenter('TEST PRINT', bold: true),
      const RlDivider(),
      const RlLeft('Printer: OK'),
      RlLeft('Width: $dots dots'),
      const RlLeft('اردو ٹیسٹ پرنٹ'),
      const RlDivider(),
      const RlItemRow('ITEM', 'QTY', 'RATE', 'AMOUNT', header: true),
      const RlItemRow('Sugar', '2 kg', '150.00', '300.00'),
      const RlDivider(),
      const RlCenter('Agar sab saaf hai to printer theek hai'),
    ];
    final img = await renderReceipt(lines, dotsWidth: dots);
    final ok = await _sendSlips(p.mac, [EscPos.rasterChunks(img.rgba, img.width, img.height)]);
    return ok ? null : 'Test print nahi hua';
  }
}
