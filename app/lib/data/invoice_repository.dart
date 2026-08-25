import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/providers.dart';
import 'customer_repository.dart' show newId, nowMs;
import 'ops.dart';

/// Line item on an invoice (computed totals stored for reporting speed).
class InvoiceLineInput {
  final String description;
  final double qty;
  final int unitPriceMinor; // minor units
  final double taxPercent;

  const InvoiceLineInput({
    required this.description,
    this.qty = 1,
    required this.unitPriceMinor,
    this.taxPercent = 0,
  });

  int get lineSubtotal => (qty * unitPriceMinor).round();
  int get lineTax => (lineSubtotal * taxPercent / 100).round();
  int get lineTotal => lineSubtotal + lineTax;
}

class InvoiceTotals {
  final int subtotal;
  final int taxTotal;
  int get total => subtotal + taxTotal;
  const InvoiceTotals(this.subtotal, this.taxTotal);
}

InvoiceTotals computeTotals(List<InvoiceLineInput> lines) => InvoiceTotals(
      lines.fold(0, (s, l) => s + l.lineSubtotal),
      lines.fold(0, (s, l) => s + l.lineTax),
    );

enum InvoiceStatus { draft, sent, partial, paid, voided }

extension InvoiceStatusX on InvoiceStatus {
  String get sqlName => this == InvoiceStatus.voided ? 'void' : name;
  static InvoiceStatus fromSql(String s) =>
      InvoiceStatus.values.where((v) => v.sqlName == s).firstOrNull ?? InvoiceStatus.draft;
}

class InvoiceRepository {
  final AppDatabase db;
  InvoiceRepository(this.db);

  Stream<List<Map<String, dynamic>>> watchAll({int limit = 500}) =>
      db.watchRows('SELECT i.*, c.name AS customer_name FROM invoices i '
          'LEFT JOIN customers c ON c.id = i.customer_id '
          'ORDER BY i.issue_date DESC, i.created_at DESC LIMIT $limit');

  Future<Map<String, dynamic>?> byId(String id) async {
    final rs = await db.rows(
        'SELECT i.*, c.name AS customer_name FROM invoices i '
        'LEFT JOIN customers c ON c.id = i.customer_id WHERE i.id = ?',
        [id]);
    return rs.isEmpty ? null : rs.first;
  }

  Future<List<Map<String, dynamic>>> lines(String invoiceId) => db
      .rows('SELECT * FROM invoice_lines WHERE invoice_id = ? ORDER BY position', [invoiceId]);

  Future<String> nextNumber() async {
    final v = await db.getSetting<String>('invoice_next_number', '1');
    final n = int.tryParse(v) ?? 1;
    await db.setSetting('invoice_next_number', '${n + 1}');
    return 'INV-${n.toString().padLeft(4, '0')}';
  }

  Future<InvoiceTotals> previewTotals(List<InvoiceLineInput> lines) async =>
      computeTotals(lines);

  /// Creates an invoice with lines atomically and records ops in the audit log.
  Future<String> create({
    required String customerId,
    required List<InvoiceLineInput> lines,
    String? dueDate,
    String? notes,
    String currency = 'USD',
    InvoiceStatus status = InvoiceStatus.draft,
  }) async {
    if (lines.isEmpty) throw ArgumentError('invoice needs at least one line');
    final id = newId();
    final number = await nextNumber();
    final t = computeTotals(lines);
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final now = nowMs();

    await db.transaction(() async {
      await db.exec(
        'INSERT INTO invoices (id, number, customer_id, status, issue_date, due_date, currency, '
        'subtotal, tax_total, total, notes, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [id, number, customerId, status.sqlName, today, dueDate, currency,
         t.subtotal, t.taxTotal, t.total, notes, now, now],
      );
      var pos = 0;
      final linePayloads = <Map<String, Object?>>[];
      for (final l in lines) {
        final lineId = newId();
        await db.exec(
          'INSERT INTO invoice_lines (id, invoice_id, description, qty, unit_price, '
          'tax_percent, line_total, position) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [lineId, id, l.description, l.qty, l.unitPriceMinor, l.taxPercent,
           l.lineTotal, pos],
        );
        linePayloads.add({
          'id': lineId, 'invoice_id': id, 'description': l.description,
          'qty': l.qty, 'unit_price': l.unitPriceMinor, 'tax_percent': l.taxPercent,
          'line_total': l.lineTotal, 'position': pos,
        });
        pos++;
      }
      await logOp(db, entity: 'invoices', entityId: id, opType: 'create', payload: {
        'id': id, 'number': number, 'customer_id': customerId,
        'status': status.sqlName, 'issue_date': today, 'due_date': dueDate,
        'currency': currency, 'subtotal': t.subtotal, 'tax_total': t.taxTotal,
        'total': t.total, 'notes': notes, 'created_at': now, 'updated_at': now,
        'lines': linePayloads,
      });
    });
    return id;
  }

  Future<void> setStatus(String id, InvoiceStatus status) async {
    final now = nowMs();
    await db.exec('UPDATE invoices SET status = ?, updated_at = ? WHERE id = ?',
        [status.sqlName, now, id]);
    final row = await byId(id);
    if (row != null) {
      row['updated_at'] = now;
      await logOp(db, entity: 'invoices', entityId: id, opType: 'update', payload: row);
    }
  }

  /// Records a payment against an invoice and updates its status:
  /// paid when fully covered, partial otherwise. Append-only payments make
  /// concurrent merges trivial in sync later.
  Future<String> addPayment(String invoiceId, int amountMinor,
      {String method = 'manual', String? reference}) async {
    final inv = await byId(invoiceId);
    if (inv == null) throw StateError('invoice not found: $invoiceId');

    final pid = newId();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final now = nowMs();
    await db.exec(
      'INSERT INTO payments (id, invoice_id, expense_id, date, amount, method, reference, '
      'created_at, updated_at) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?)',
      [pid, invoiceId, today, amountMinor, method, reference, now, now],
    );
    await logOp(db, entity: 'payments', entityId: pid, opType: 'create', payload: {
      'id': pid, 'invoice_id': invoiceId, 'expense_id': null, 'date': today,
      'amount': amountMinor, 'method': method, 'reference': reference,
      'created_at': now, 'updated_at': now,
    });

    final paid = await db.rows(
        'SELECT COALESCE(SUM(amount),0) AS p FROM payments WHERE invoice_id = ?',
        [invoiceId]).then((rs) => rs.first['p'] as int);
    final total = inv['total'] as int;
    final newStatus = paid >= total ? InvoiceStatus.paid : InvoiceStatus.partial;
    await setStatus(invoiceId, newStatus);
    return pid;
  }

  Future<int> paidAmount(String invoiceId) async {
    final rs = await db.rows(
        'SELECT COALESCE(SUM(amount),0) AS p FROM payments WHERE invoice_id = ?',
        [invoiceId]);
    return rs.first['p'] as int;
  }

  Future<List<Map<String, dynamic>>> unpaid() => db
      .rows("SELECT i.*, c.name AS customer_name FROM invoices i "
          "LEFT JOIN customers c ON c.id = i.customer_id "
          "WHERE i.status IN ('sent','partial') ORDER BY i.due_date");
}

final invoiceRepoProvider =
    Provider<InvoiceRepository>((ref) => InvoiceRepository(ref.read(appDbProvider)));
