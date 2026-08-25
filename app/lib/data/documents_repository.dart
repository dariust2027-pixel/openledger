import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/providers.dart';
import 'customer_repository.dart' show newId, nowMs;
import 'invoice_repository.dart' as inv show InvoiceLineInput, InvoiceRepository;
import 'invoice_repository.dart' show invoiceRepoProvider;
import 'items_repository.dart';
import 'ops.dart';

enum DocType { quote, salesOrder, purchaseOrder, bill }

extension DocTypeX on DocType {
  String get sqlName => switch (this) {
        DocType.quote => 'quote',
        DocType.salesOrder => 'sales_order',
        DocType.purchaseOrder => 'purchase_order',
        DocType.bill => 'bill',
      };
  String get label => switch (this) {
        DocType.quote => 'Quote',
        DocType.salesOrder => 'Sales Order',
        DocType.purchaseOrder => 'Purchase Order',
        DocType.bill => 'Bill',
      };
  /// Sales docs reference customers; purchasing docs reference vendors.
  bool get isSales =>
      this == DocType.quote || this == DocType.salesOrder;
}

class DocLineInput {
  final String? itemId;
  final String description;
  final double qty;
  final int unitPriceMinor;
  final double taxPercent;

  const DocLineInput({
    this.itemId,
    required this.description,
    this.qty = 1,
    required this.unitPriceMinor,
    this.taxPercent = 0,
  });

  int get lineTotal =>
      (qty * unitPriceMinor).round() + ((qty * unitPriceMinor).round() * taxPercent / 100).round();

  Map<String, Object?> toJson() => {
        'item_id': itemId, 'description': description, 'qty': qty,
        'unit_price': unitPriceMinor, 'tax_percent': taxPercent,
      };
}

class DocumentRepository {
  final AppDatabase db;
  final ItemRepository items;
  final inv.InvoiceRepository invoices;

  DocumentRepository(this.db, this.items, this.invoices);

  String _prefix(DocType t) => switch (t) {
        DocType.quote => 'QT',
        DocType.salesOrder => 'SO',
        DocType.purchaseOrder => 'PO',
        DocType.bill => 'BILL',
      };

  Future<String> _nextNumber(DocType t) async {
    final key = 'doc_next_${t.sqlName}';
    final v = await db.getSetting<String>(key, '1');
    final n = int.tryParse(v) ?? 1;
    await db.setSetting(key, '${n + 1}');
    return '${_prefix(t)}-${n.toString().padLeft(4, '0')}';
  }

  Stream<List<Map<String, dynamic>>> watchByType(DocType t, {String? partyJoin}) => db
      .watchRows(
          'SELECT d.*, ${t.isSales ? 'c.name' : 'v.name'} AS party_name '
          'FROM documents d '
          'LEFT JOIN ${t.isSales ? 'customers c' : 'vendors v'} '
          'ON ${t.isSales ? 'c.id' : 'v.id'} = d.party_id '
          "WHERE d.doc_type = '${t.sqlName}' "
          'ORDER BY d.date DESC, d.created_at DESC LIMIT 500');

  Future<Map<String, dynamic>?> byId(String id) async {
    final rs = await db.rows('SELECT * FROM documents WHERE id = ?', [id]);
    return rs.isEmpty ? null : rs.first;
  }

  Future<List<Map<String, dynamic>>> lines(String docId) => db
      .rows('SELECT * FROM document_lines WHERE document_id = ? ORDER BY position', [docId]);

  Future<String> create({
    required DocType type,
    required String partyId,
    required List<DocLineInput> lines,
    String? dueDate,
    String? notes,
    String currency = 'USD',
    String? date,
  }) async {
    if (lines.isEmpty) throw ArgumentError('document needs at least one line');
    final id = newId();
    final number = await _nextNumber(type);
    final subtotal =
        lines.fold<int>(0, (s, l) => s + (l.qty * l.unitPriceMinor).round());
    final tax = lines.fold<int>(
        0, (s, l) => s + ((l.qty * l.unitPriceMinor).round() * l.taxPercent / 100).round());
    final now = nowMs();
    final docDate = date ?? DateTime.now().toIso8601String().substring(0, 10);

    await db.transaction(() async {
      await db.exec(
        'INSERT INTO documents (id, doc_type, number, party_id, status, date, due_date, '
        'currency, subtotal, tax_total, total, notes, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [id, type.sqlName, number, partyId, 'draft', docDate, dueDate, currency,
         subtotal, tax, subtotal + tax, notes, now, now],
      );
      var pos = 0;
      for (final l in lines) {
        await db.exec(
          'INSERT INTO document_lines (id, document_id, item_id, description, qty, '
          'unit_price, tax_percent, line_total, position) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [newId(), id, l.itemId, l.description, l.qty, l.unitPriceMinor,
           l.taxPercent, l.lineTotal, pos],
        );
        pos++;
      }
      // Stock movements:
      //   bill (stock purchase)  -> stock IN
      //   purchase order         -> nothing until goods received
      //   quote / sales order    -> nothing until invoiced
      if (type == DocType.bill) {
        for (final l in lines.where((l) => l.itemId != null)) {
          await items.adjustStock(l.itemId!, l.qty);
        }
      }
      await logOp(db, entity: 'documents', entityId: id, opType: 'create', payload: {
        'id': id, 'doc_type': type.sqlName, 'number': number, 'party_id': partyId,
        'status': 'draft', 'date': docDate, 'due_date': dueDate, 'currency': currency,
        'subtotal': subtotal, 'tax_total': tax, 'total': subtotal + tax,
        'notes': notes, 'created_at': now, 'updated_at': now,
        'lines': [for (final l in lines) l.toJson()],
      });
    });
    return id;
  }

  Future<void> setStatus(String id, String status) async {
    await db.exec('UPDATE documents SET status = ?, updated_at = ? WHERE id = ?',
        [status, nowMs(), id]);
    await logOp(db, entity: 'documents', entityId: id, opType: 'update',
        payload: {'status': status});
  }

  Future<int> paidAmount(String docId) async {
    final rs = await db.rows(
        'SELECT COALESCE(SUM(amount),0) AS p FROM payments WHERE doc_id = ?', [docId]);
    return rs.first['p'] as int;
  }

  /// Record a payment made against a bill (money OUT).
  Future<String> payBill(String docId, int amountMinor, {String method = 'bank'}) async {
    final pid = newId();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final now = nowMs();
    await db.exec(
      'INSERT INTO payments (id, invoice_id, expense_id, doc_id, date, amount, method, '
      'reference, created_at, updated_at) VALUES (?, NULL, NULL, ?, ?, ?, ?, NULL, ?, ?)',
      [pid, docId, today, amountMinor, method, now, now],
    );
    final doc = await byId(docId);
    if (doc != null) {
      final paid = await paidAmount(docId);
      await setStatus(docId, paid >= (doc['total'] as int) ? 'paid' : 'partial');
    }
    await logOp(db, entity: 'payments', entityId: pid, opType: 'create', payload: {
      'id': pid, 'doc_id': docId, 'date': today, 'amount': amountMinor,
      'method': method, 'created_at': now, 'updated_at': now,
    });
    return pid;
  }

  /// Converts an accepted quote (or sales order) into a real invoice.
  /// Stock decrements happen inside InvoiceRepository.create via item links.
  Future<String> convertToInvoice(String quoteId) async {
    final doc = await byId(quoteId);
    if (doc == null) throw StateError('document not found');
    if (doc['converted_doc_id'] != null) {
      throw StateError('already converted to ${doc['converted_doc_id']}');
    }
    final docLines = await lines(quoteId);
    final invoiceId = await invoices.create(
      customerId: doc['party_id'] as String,
      lines: [
        for (final l in docLines)
          inv.InvoiceLineInput(
            itemId: l['item_id'] as String?,
            description: l['description'] as String,
            qty: (l['qty'] as num).toDouble(),
            unitPriceMinor: l['unit_price'] as int,
            taxPercent: (l['tax_percent'] as num?)?.toDouble() ?? 0,
          ),
      ],
      notes: 'From ${doc['number']}',
      currency: doc['currency'] as String? ?? 'USD',
    );
    await db.exec('UPDATE documents SET converted_doc_id = ?, status = ?, updated_at = ? WHERE id = ?',
        [invoiceId, 'converted', nowMs(), quoteId]);
    await logOp(db, entity: 'documents', entityId: quoteId, opType: 'update',
        payload: {'status': 'converted', 'converted_doc_id': invoiceId});
    return invoiceId;
  }
}

final documentRepoProvider = Provider<DocumentRepository>((ref) =>
    DocumentRepository(
        ref.read(appDbProvider), ref.read(itemRepoProvider), ref.read(invoiceRepoProvider)));
