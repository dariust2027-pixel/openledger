import 'package:flutter_test/flutter_test.dart';
import 'package:openledger/data/invoice_repository.dart';
import 'package:openledger/domain/money.dart';

void main() {
  group('Money', () {
    test('stores minor units exactly', () {
      final m = Money.fromMajor(19.99);
      expect(m.minorUnits, 1999);
      expect(m.formatted(), '\$19.99');
    });

    test('addition is exact (no float drift)', () {
      final sum = Money.fromMajor(0.1) + Money.fromMajor(0.2);
      expect(sum.minorUnits, 30);
    });
  });

  group('InvoiceTotals', () {
    test('computes subtotal, tax and total', () {
      final lines = [
        const InvoiceLineInput(description: 'A', qty: 3, unitPriceMinor: 9000, taxPercent: 10),
        const InvoiceLineInput(description: 'B', unitPriceMinor: 2500),
      ];
      final t = computeTotals(lines);
      expect(t.subtotal, 29500);
      expect(t.taxTotal, 2700);
      expect(t.total, 32200);
    });
  });
}
