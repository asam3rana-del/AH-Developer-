import 'dart:async';
import 'dart:io' show Platform, Socket;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:printing/printing.dart';

import '../db/user_repository.dart';
import '../utils/bill_doc.dart';
import '../utils/escpos.dart';
import '../utils/receipt_lines.dart';
import 'receipt_renderer.dart';
import 'usb_printer.dart';

class PrinterInfo {
  final String name;
  final String mac;
  const PrinterInfo(this.name, this.mac);
}

/// Kotlin PrinterHelper ka Flutter hissa: Bluetooth (58mm/80mm ESC/POS raster).
/// Windows/desktop: installed printer (USB, driver ke zariye PDF roll) ya Network printer (IP, raw ESC/POS).
/// Android par USB (host mode) bhi: lib/services/usb_printer.dart (MethodChannel, plugin nahi). iOS par sirf Bluetooth.
/// Settings keys Kotlin wali hi: printer_name, printer_mac, printer_width, printer_dots.
class PrinterService {
  PrinterService._();
  static final PrinterService instance = PrinterService._();

  final _repo = UserRepository.instance;

  /// Bluetooth printer (Android / iOS).
  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Windows / Linux / macOS: Bluetooth nahi — installed (USB) printer ya network (IP) printer.
  static bool get isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// Kisi bhi tarah print ho sakti hai?
  static bool get canPrint => supported || isDesktop;

  /// `printer_mac` setting mein transport ka prefix (purani Bluetooth MAC bina prefix ke hi rehti hain).
  static const tcpPrefix = 'tcp:'; // tcp:192.168.1.50:9100
  static const sysPrefix = 'sys:'; // sys:<Windows printer ka url/naam>
  static const usbPrefix = UsbPrinter.prefix; // usb:<vid>:<pid> (sirf Android)
  static bool isUsb(String addr) => UsbPrinter.isUsb(addr);
  static bool isTcp(String addr) => addr.startsWith(tcpPrefix);
  static bool isSystem(String addr) => addr.startsWith(sysPrefix);

  /// Windows/desktop par install kiye hue printers (USB thermal bhi, agar driver install hai).
  Future<List<PrinterInfo>> systemPrinters() async {
    if (!isDesktop) return [];
    final list = await Printing.listPrinters();
    return [for (final p in list) PrinterInfo(p.name, '$sysPrefix${p.url}')];
  }

  /// Network printer (IP:port, aam taur par 9100) ka address save karne ke liye. null => ghalat format.
  static String? tcpAddress(String input) {
    final t = input.trim();
    if (t.isEmpty) return null;
    final parts = t.split(':');
    final host = parts.first.trim();
    final port = parts.length > 1 ? int.tryParse(parts[1].trim()) : 9100;
    if (host.isEmpty || host.contains(' ') || port == null || port < 1 || port > 65535 || parts.length > 2) return null;
    return '$tcpPrefix$host:$port';
  }

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
      var ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
      if (!ok) {
        // Ek baar dobara koshish (printer kabhi pehli connect par jawab nahi deta).
        await _sleep(700);
        await PrintBluetoothThermal.disconnect;
        ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
      }
      if (!ok) return false;
      await _sleep(EscPos.connectSettleDelayMs);
      var allOk = true;
      for (var s = 0; s < slips.length && allOk; s++) {
        allOk &= await PrintBluetoothThermal.writeBytes(EscPos.init.toList());
        await _sleep(EscPos.settleDelayMs);
        for (final chunk in slips[s]) {
          final b = chunk.bytes;
          var off = 0;
          while (off < b.length) {
            final end = off + EscPos.btWritePieceBytes > b.length ? b.length : off + EscPos.btWritePieceBytes;
            allOk &= await PrintBluetoothThermal.writeBytes(b.sublist(off, end).toList());
            off = end;
            if (!allOk) break;
            if (off < b.length) await _sleep(EscPos.btWritePieceGapMs);
          }
          if (!allOk) break;
          await _sleep(EscPos.interChunkDelayMs(chunk.stripHeight));
        }
        if (!allOk) break;
        await _sleep(EscPos.settleDelayMs);
        allOk &= await PrintBluetoothThermal.writeBytes(EscPos.feedAndCut.toList());
        if (s < slips.length - 1) await _sleep(EscPos.settleDelayMs);
      }
      // Socket foran band karne se bill ka akhri hissa kat jata tha — printer ko poora print karne dein.
      await _sleep(EscPos.closeDrainDelayMs);
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

  /// Network (raw ESC/POS, TCP 9100). Bluetooth jaisa hi data, bas tez.
  Future<bool> _sendTcp(String addr, List<List<({Uint8List bytes, int stripHeight})>> slips) async {
    Socket? socket;
    try {
      final hp = addr.substring(tcpPrefix.length);
      final i = hp.lastIndexOf(':');
      final host = hp.substring(0, i);
      final port = int.parse(hp.substring(i + 1));
      socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      for (var s = 0; s < slips.length; s++) {
        socket.add(EscPos.init);
        for (final chunk in slips[s]) {
          socket.add(chunk.bytes);
        }
        socket.add(EscPos.feedAndCut);
        await socket.flush();
        if (s < slips.length - 1) await _sleep(EscPos.settleDelayMs);
      }
      await _sleep(EscPos.closeDrainDelayMs);
      return true;
    } catch (e) {
      debugPrint('network print failed: $e');
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  /// Android USB (host mode): Bluetooth jaisa hi sequence — init -> strips (pause ke saath) -> feed+cut.
  /// Kotlin sendUsbChunks ki tarah ek baar device khol kar; 4096-byte tukde Kotlin side par.
  Future<String?> _sendUsb(String addr, List<List<({Uint8List bytes, int stripHeight})>> slips) async {
    final id = UsbPrinter.parse(addr);
    if (id == null) return 'USB printer ka address ghalat — Settings mein dobara select karein';
    if (!UsbPrinter.supported) return 'USB printer sirf Android par hai';
    try {
      final attached = await UsbPrinter.list();
      if (!attached.any((d) => d.vid == id.vid && d.pid == id.pid)) {
        return 'USB printer nahi mila — cable lagi hai? Printer on hai?';
      }
      if (!await UsbPrinter.requestPermission(id.vid, id.pid)) {
        return 'USB ki ijazat nahi mili — "Allow" dabayein aur dobara koshish karein';
      }
      if (!await UsbPrinter.open(id.vid, id.pid)) return 'USB printer khul nahi saka — cable nikaal kar dobara lagayein';
      var allOk = true;
      for (var s = 0; s < slips.length; s++) {
        allOk &= await UsbPrinter.write(EscPos.init);
        await _sleep(EscPos.settleDelayMs);
        for (final chunk in slips[s]) {
          allOk &= await UsbPrinter.write(chunk.bytes);
          await _sleep(EscPos.interChunkDelayMs(chunk.stripHeight));
          if (!allOk) break;
        }
        if (!allOk) break;
        await _sleep(EscPos.settleDelayMs);
        allOk &= await UsbPrinter.write(EscPos.feedAndCut);
        if (s < slips.length - 1) await _sleep(EscPos.settleDelayMs);
      }
      await _sleep(EscPos.closeDrainDelayMs);
      return allOk ? null : 'Print nahi hua — USB printer on hai? Dobara koshish karein';
    } catch (e) {
      debugPrint('usb print failed: $e');
      return 'Print nahi hua — USB printer on hai? Dobara koshish karein';
    } finally {
      await UsbPrinter.close();
    }
  }

  /// Windows ka installed printer (driver ke zariye): receipt image ko roll-size PDF page bana kar seedha print.
  Future<bool> _sendSystem(String addr, List<ReceiptImage> images, int dots) async {
    try {
      final url = addr.substring(sysPrefix.length);
      final printers = await Printing.listPrinters();
      final match = printers.where((p) => p.url == url).toList();
      if (match.isEmpty) return false; // printer hata diya gaya / offline
      final widthMm = dots <= 448 ? 58.0 : 80.0;
      for (final img in images) {
        final png = await _toPng(img);
        final heightMm = widthMm * img.height / img.width;
        final format = PdfPageFormat(widthMm * PdfPageFormat.mm, heightMm * PdfPageFormat.mm, marginAll: 0);
        final doc = pw.Document();
        final image = pw.MemoryImage(png);
        doc.addPage(pw.Page(
          pageFormat: format,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(image, fit: pw.BoxFit.fill, width: format.width, height: format.height),
        ));
        final bytes = await doc.save();
        final ok = await Printing.directPrintPdf(
          printer: match.first,
          onLayout: (_) async => bytes,
          name: 'Receipt',
          format: format,
        );
        if (!ok) return false;
      }
      return true;
    } catch (e) {
      debugPrint('system print failed: $e');
      return false;
    }
  }

  Future<Uint8List> _toPng(ReceiptImage img) async {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(img.rgba, img.width, img.height, ui.PixelFormat.rgba8888, c.complete);
    final image = await c.future;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// Transport ke hisaab se bhejta hai. null = ok, warna error.
  Future<String?> _dispatch(PrinterInfo p, List<ReceiptImage> images, int dots) async {
    final addr = p.mac;
    if (isSystem(addr)) {
      return await _sendSystem(addr, images, dots)
          ? null
          : 'Print nahi hua — Windows printer install/on hai? Dobara koshish karein';
    }
    final slips = [for (final img in images) EscPos.rasterChunks(img.rgba, img.width, img.height)];
    if (isTcp(addr)) {
      return await _sendTcp(addr, slips)
          ? null
          : 'Network printer se connect nahi hua — IP/port theek hai? Printer on hai?';
    }
    if (isUsb(addr)) return _sendUsb(addr, slips);
    // Bluetooth
    if (!supported) return 'Bluetooth printer sirf Android / iOS par hai — Settings mein Windows ya Network printer chunein';
    if (!await hasPermission()) return 'Bluetooth permission dein';
    if (!await bluetoothOn()) return 'Bluetooth on karein';
    return await _sendSlips(addr, slips) ? null : 'Print nahi hua — printer on/paired hai? Dobara koshish karein';
  }

  /// Kotlin printReceiptLinesPaged(): bill print, lambi ho to kai slips.
  /// Return null = ok, warna error message.
  Future<String?> printBill(BillDoc doc, {double? netBalance, int maxItemsPerPage = 18}) async {
    final p = await selected();
    if (p == null) return 'Pehle Settings mein printer select karein';
    final dots = await dotsWidth();
    final pages = paginateReceipt(
      header: receiptHeader(doc),
      items: receiptItems(doc),
      footer: receiptFooter(doc, netBalance: netBalance),
      maxItemsPerPage: maxItemsPerPage,
    );
    final images = <ReceiptImage>[];
    for (final lines in pages) {
      images.add(await renderReceipt(lines, dotsWidth: dots));
    }
    return _dispatch(p, images, dots);
  }

  /// Kotlin printText(): sirf plain ASCII text (raster nahi). Bluetooth, Network aur USB par; Windows driver
  /// printer ke liye raster print hi chalta hai. null = ok, warna error.
  Future<String?> printText(String text) async {
    final p = await selected();
    if (p == null) return 'Pehle printer select karein';
    final addr = p.mac;
    if (isSystem(addr)) return 'Windows printer par plain text nahi — TEST PRINT (raster) use karein';
    final payload = EscPos.textPayload(text);
    if (isUsb(addr)) {
      final id = UsbPrinter.parse(addr);
      if (id == null) return 'USB printer ka address ghalat — Settings mein dobara select karein';
      if (!UsbPrinter.supported) return 'USB printer sirf Android par hai';
      try {
        final attached = await UsbPrinter.list();
        if (!attached.any((d) => d.vid == id.vid && d.pid == id.pid)) {
          return 'USB printer nahi mila — cable lagi hai? Printer on hai?';
        }
        if (!await UsbPrinter.requestPermission(id.vid, id.pid)) {
          return 'USB ki ijazat nahi mili — "Allow" dabayein aur dobara koshish karein';
        }
        if (!await UsbPrinter.open(id.vid, id.pid)) return 'USB printer khul nahi saka — cable nikaal kar dobara lagayein';
        return await UsbPrinter.write(payload) ? null : 'Print nahi hua — USB printer on hai? Dobara koshish karein';
      } catch (e) {
        debugPrint('usb text print failed: $e');
        return 'Print nahi hua — USB printer on hai? Dobara koshish karein';
      } finally {
        await UsbPrinter.close();
      }
    }
    if (isTcp(addr)) {
      Socket? socket;
      try {
        final hp = addr.substring(tcpPrefix.length);
        final i = hp.lastIndexOf(':');
        socket = await Socket.connect(hp.substring(0, i), int.parse(hp.substring(i + 1)), timeout: const Duration(seconds: 5));
        socket.add(payload);
        await socket.flush();
        await _sleep(EscPos.settleDelayMs);
        return null;
      } catch (e) {
        debugPrint('network text print failed: $e');
        return 'Network printer se connect nahi hua — IP/port theek hai? Printer on hai?';
      } finally {
        try {
          await socket?.close();
        } catch (_) {}
      }
    }
    if (!supported) return 'Bluetooth printer sirf Android / iOS par hai';
    if (!await hasPermission()) return 'Bluetooth permission dein';
    if (!await bluetoothOn()) return 'Bluetooth on karein';
    try {
      await PrintBluetoothThermal.disconnect;
      if (!await PrintBluetoothThermal.connect(macPrinterAddress: addr)) {
        return 'Print nahi hua — printer on/paired hai? Dobara koshish karein';
      }
      var ok = true;
      for (var off = 0; off < payload.length; off += EscPos.btWritePieceBytes) {
        final end = off + EscPos.btWritePieceBytes > payload.length ? payload.length : off + EscPos.btWritePieceBytes;
        ok &= await PrintBluetoothThermal.writeBytes(payload.sublist(off, end).toList());
        if (end < payload.length) await _sleep(EscPos.btWritePieceGapMs);
      }
      await _sleep(EscPos.closeDrainDelayMs);
      return ok ? null : 'Print nahi hua — printer on/paired hai? Dobara koshish karein';
    } catch (e) {
      debugPrint('text print failed: $e');
      return 'Print nahi hua — printer on/paired hai? Dobara koshish karein';
    } finally {
      try {
        await PrintBluetoothThermal.disconnect;
      } catch (_) {}
    }
  }

  /// Kotlin testPrint(): plain-text slip. Raster test garbled ho to ye batata hai ke printer/connection theek hai.
  Future<String?> testPrintText({String shopName = ''}) async {
    final p = await selected();
    final conn = p == null ? 'BLUETOOTH' : (isTcp(p.mac) ? 'NETWORK' : (isUsb(p.mac) ? 'USB' : 'BLUETOOTH'));
    return printText(EscPos.testText(shopName: shopName, connection: conn));
  }

  Future<String?> testPrint({String shopName = ''}) async {
    final p = await selected();
    if (p == null) return 'Pehle printer select karein';
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
    return _dispatch(p, [img], dots);
  }
}
