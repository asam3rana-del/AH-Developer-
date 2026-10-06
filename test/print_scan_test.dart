import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ah_developer_kiryana_store/services/printer_service.dart';
import 'package:ah_developer_kiryana_store/services/usb_printer.dart';
import 'package:ah_developer_kiryana_store/utils/bill_doc.dart';
import 'package:ah_developer_kiryana_store/utils/bill_scan_parser.dart';
import 'package:ah_developer_kiryana_store/utils/escpos.dart';
import 'package:ah_developer_kiryana_store/utils/receipt_lines.dart';

BillDoc _doc(int n, {bool purchase = false}) => BillDoc(
      isPurchase: purchase,
      ref: 'INV-1',
      date: DateTime(2026, 9, 29, 14, 30),
      partyName: 'Ali',
      items: [for (var i = 1; i <= n; i++) BillItem(name: 'Item $i', qty: 2, unit: 'kg', rate: 10, amount: 20)],
      subtotal: 20.0 * n,
      discount: 0,
      total: 20.0 * n,
      paid: 10,
    );

void main() {
  _desktopPrinterTests();
  group('EscPos', () {
    test('normalizeDotsWidth clamps and rounds to a multiple of 8', () {
      expect(EscPos.normalizeDotsWidth(null), 384);
      expect(EscPos.normalizeDotsWidth(100), 256);
      expect(EscPos.normalizeDotsWidth(9999), 576);
      expect(EscPos.normalizeDotsWidth(450), 448);
    });

    test('interChunkDelay has a floor and scales with strip height', () {
      expect(EscPos.interChunkDelayMs(5), 200);
      expect(EscPos.interChunkDelayMs(24), 240);
    });

    test('rasterChunks: header, strip split and black pixel bit', () {
      const w = 16, h = 50;
      final rgba = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255); // all white
      // Pixel (x=0,y=0) black, pixel (x=9,y=30) black.
      void black(int x, int y) {
        final p = (y * w + x) * 4;
        rgba[p] = 0;
        rgba[p + 1] = 0;
        rgba[p + 2] = 0;
      }

      black(0, 0);
      black(9, 30);
      final chunks = EscPos.rasterChunks(rgba, w, h);
      expect(chunks.map((c) => c.stripHeight).toList(), [24, 24, 2]);
      final first = chunks.first.bytes;
      expect(first.sublist(0, 8), [0x1D, 0x76, 0x30, 0x00, 2, 0, 24, 0]);
      expect(first[8], 0x80); // x=0 => top bit of byte 0, row 0
      expect(first.length, 8 + 2 * 24);
      // y=30 is row 6 of the second strip; x=9 => byte 1, bit 6 (1 << (7-1)).
      final second = chunks[1].bytes;
      expect(second[8 + 6 * 2 + 1], 0x40);
    });

    test('PrintPacing: safe is slower and smaller than normal', () {
      expect(PrintPacing.safe.stripHeightPx, lessThan(PrintPacing.normal.stripHeightPx));
      expect(PrintPacing.safe.pieceBytes, lessThan(PrintPacing.normal.pieceBytes));
      expect(PrintPacing.safe.delayFor(1), PrintPacing.safe.minDelayMs);
      expect(PrintPacing.normal.delayFor(24), EscPos.interChunkDelayMs(24));
    });

    test('rasterChunks honours a smaller strip height', () {
      const w = 16, h = 40;
      final rgba = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
      final chunks = EscPos.rasterChunks(rgba, w, h, maxStripHeight: PrintPacing.safe.stripHeightPx);
      expect(chunks.map((c) => c.stripHeight).toList(), [16, 16, 8]);
    });

    test('transparent pixels stay white', () {
      final rgba = Uint8List(8 * 1 * 4); // all zero alpha
      final c = EscPos.rasterChunks(rgba, 8, 1);
      expect(c.single.bytes.last, 0);
    });
  });

  group('paginateReceipt', () {
    List<List<ReceiptLine>> pages(int n, int per) {
      final d = _doc(n);
      return paginateReceipt(
        header: receiptHeader(d),
        items: receiptItems(d),
        footer: receiptFooter(d),
        maxItemsPerPage: per,
      );
    }

    test('short bill = one slip with footer', () {
      final p = pages(5, 18);
      expect(p.length, 1);
      expect(p.first.whereType<RlTwoCol>().any((l) => l.left == 'TOTAL'), isTrue);
    });

    test('long bill splits; footer only on last slip; continuation markers', () {
      final p = pages(40, 18); // 18 + 18 + 4
      expect(p.length, 3);
      bool hasTotal(List<ReceiptLine> l) => l.whereType<RlTwoCol>().any((x) => x.left == 'TOTAL');
      expect(hasTotal(p[0]), isFalse);
      expect(hasTotal(p[1]), isFalse);
      expect(hasTotal(p[2]), isTrue);
      bool has(List<ReceiptLine> l, String t) => l.whereType<RlCenter>().any((x) => x.text.contains(t));
      expect(has(p[0], 'Continued on next slip'), isTrue);
      expect(has(p[1], 'Page 2 of 3'), isTrue);
      expect(has(p[2], 'Page 3 of 3'), isTrue);
      // Table header repeated on every slip; item rows split 18/18/4.
      for (final s in p) {
        expect(s.whereType<RlItemRow>().where((r) => r.header).length, 1);
      }
      expect(p.map((s) => s.whereType<RlItemRow>().where((r) => !r.header).length).toList(), [18, 18, 4]);
    });

    test('exactly maxItemsPerPage stays a single slip', () {
      expect(pages(18, 18).length, 1);
    });

    test('footer shows Prev/Net balance only with a party id', () {
      final d = BillDoc(
        isPurchase: false,
        ref: 'I',
        date: DateTime(2026),
        items: const [],
        subtotal: 100,
        discount: 0,
        total: 100,
        paid: 40,
        partyId: 3,
      );
      final f = receiptFooter(d, netBalance: 260);
      final prev = f.whereType<RlTwoCol>().firstWhere((l) => l.left == 'Prev Balance');
      expect(prev.right, '200.00'); // 260 - due(60)
      expect(receiptFooter(d).whereType<RlTwoCol>().any((l) => l.left == 'Net Balance'), isFalse);
    });
  });

  group('BillDoc.toText', () {
    test('sale + purchase texts', () {
      expect(_doc(1).toText(), contains('Customer: Ali'));
      expect(_doc(1, purchase: true).toText(), contains('PURCHASE BILL'));
      expect(_doc(1).balance, 10);
    });
  });

  group('parseBillText', () {
    test('qty x rate = amount lines', () {
      final l = parseBillText('Sugar 2 150 300\nRice 5 x 200 1000');
      expect(l.length, 2);
      expect(l[0].name, 'Sugar');
      expect(l[0].qty, '2');
      expect(l[0].rate, '150');
      expect(l[1].name, 'Rice');
      expect(l[1].qty, '5');
      expect(l[1].rate, '200');
    });

    test('skips totals, dates, phone and pure-number lines', () {
      final l = parseBillText('SHOP NAME\nDate 12/05/2026\nTotal 1300\nPaid 1000\n-----\n12345\nOil 1 480');
      expect(l.any((e) => e.name == 'Oil'), isTrue);
      expect(l.any((e) => e.name.toLowerCase().contains('total')), isFalse);
    });

    test('single number = rate with qty 1', () {
      final l = parseBillText('Soap 85');
      expect(l.single.qty, '1');
      expect(l.single.rate, '85');
    });
  });

  group('confirmedItems', () {
    test('only ticked, valid rows', () {
      final items = confirmedItems([
        ScannedLine(name: 'A', qty: '2', rate: '10'),
        ScannedLine(name: 'B', qty: '2', rate: '10', include: false),
        ScannedLine(name: '', qty: '2', rate: '10'),
        ScannedLine(name: 'C', qty: '0', rate: '10'),
        ScannedLine(name: 'D', qty: '1', rate: ''),
      ]);
      expect(items.length, 1);
      expect(items.single.name, 'A');
      expect(items.single.qty, 2);
    });
  });
}

// Windows / desktop printer transport (Network IP printer address parsing).
void _desktopPrinterTests() {
  group('PrinterService.tcpAddress', () {
    test('IP => default port 9100', () {
      expect(PrinterService.tcpAddress('192.168.1.50'), 'tcp:192.168.1.50:9100');
    });
    test('IP:port', () {
      expect(PrinterService.tcpAddress(' 192.168.1.50:9101 '), 'tcp:192.168.1.50:9101');
    });
    test('ghalat input => null', () {
      expect(PrinterService.tcpAddress(''), isNull);
      expect(PrinterService.tcpAddress('abc def'), isNull);
      expect(PrinterService.tcpAddress('1.2.3.4:99999'), isNull);
      expect(PrinterService.tcpAddress('1.2.3.4:x'), isNull);
      expect(PrinterService.tcpAddress('1.2.3.4:1:2'), isNull);
    });
    test('transport prefix pehchan', () {
      expect(PrinterService.isTcp('tcp:1.2.3.4:9100'), isTrue);
      expect(PrinterService.isSystem('sys:Receipt Printer'), isTrue);
      expect(PrinterService.isTcp('AA:BB:CC:DD:EE:FF'), isFalse); // Bluetooth MAC
      expect(PrinterService.isSystem('AA:BB:CC:DD:EE:FF'), isFalse);
      expect(PrinterService.isUsb('usb:1155:22304'), isTrue);
      expect(PrinterService.isUsb('AA:BB:CC:DD:EE:FF'), isFalse);
      expect(PrinterService.isTcp('usb:1155:22304'), isFalse);
    });
  });

  group('UsbPrinter address', () {
    test('address <-> parse roundtrip', () {
      final a = UsbPrinter.address(1155, 22304);
      expect(a, 'usb:1155:22304');
      final id = UsbPrinter.parse(a)!;
      expect(id.vid, 1155);
      expect(id.pid, 22304);
    });
    test('ghalat format => null', () {
      expect(UsbPrinter.parse('AA:BB:CC:DD:EE:FF'), isNull);
      expect(UsbPrinter.parse('usb:1155'), isNull);
      expect(UsbPrinter.parse('usb:a:b'), isNull);
      expect(UsbPrinter.parse('usb:-1:5'), isNull);
      expect(UsbPrinter.parse('usb:1:2:3'), isNull);
    });
    test('UsbPrinterInfo.address', () {
      expect(const UsbPrinterInfo(1, 2, 'x').address, 'usb:1:2');
    });
  });

  group('plain text print (Kotlin printText)', () {
    test('payload = init + ASCII text + feed/cut', () {
      final b = EscPos.textPayload('Hi\nOK');
      expect(b.sublist(0, 2), EscPos.init);
      expect(b.sublist(b.length - 4), EscPos.feedAndCut);
      expect(String.fromCharCodes(b.sublist(2, b.length - 4)), 'Hi\nOK');
    });

    test('non-ASCII (Urdu) becomes ? and tab becomes space, CRLF becomes LF', () {
      final b = EscPos.textPayload('a\tb\r\nاب');
      expect(String.fromCharCodes(b.sublist(2, b.length - 4)), 'a b\n??');
    });

    test('test slip uses shop name or default and shows connection', () {
      expect(EscPos.testText(shopName: ' Ali Store ', connection: 'NETWORK'), contains('Ali Store'));
      expect(EscPos.testText(), contains('IBTISAAM Kiryana Store'));
      expect(EscPos.testText(connection: 'USB'), contains('Connection: USB'));
    });
  });
}
