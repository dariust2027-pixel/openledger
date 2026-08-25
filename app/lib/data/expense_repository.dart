import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/providers.dart';
import 'customer_repository.dart' show newId, nowMs;
import 'ops.dart';

class ExpenseRepository {
  final AppDatabase db;
  ExpenseRepository(this.db);

  Stream<List<Map<String, dynamic>>> watchAll({int limit = 500}) =>
      db.watchRows('SELECT e.*, c.name AS category_name FROM expenses e '
          'LEFT JOIN categories c ON c.id = e.category_id '
          'ORDER BY e.date DESC, e.created_at DESC LIMIT $limit');

  Future<List<Map<String, dynamic>>> categories() =>
      db.rows("SELECT * FROM categories WHERE kind = 'expense' ORDER BY name");

  Future<String> create({
    required int amountMinor,
    required DateTime date,
    String? vendor,
    String? categoryId,
    String? description,
    int taxMinor = 0,
    String currency = 'USD',
    String paymentMethod = 'card',
    String? receiptPath,
    bool billable = false,
  }) async {
    final id = newId();
    final created = nowMs();
    final dateStr = date.toIso8601String().substring(0, 10);
    await db.exec(
      'INSERT INTO expenses (id, date, vendor, category_id, description, amount, tax_amount, '
      'currency, payment_method, receipt_path, billable, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        dateStr,
        vendor,
        categoryId,
        description,
        amountMinor,
        taxMinor,
        currency,
        paymentMethod,
        receiptPath,
        billable ? 1 : 0,
        created,
        created,
      ],
    );
    await logOp(db, entity: 'expenses', entityId: id, opType: 'create', payload: {
      'id': id, 'date': dateStr, 'vendor': vendor, 'category_id': categoryId,
      'description': description, 'amount': amountMinor, 'tax_amount': taxMinor,
      'currency': currency, 'payment_method': paymentMethod, 'receipt_path': receiptPath,
      'billable': billable ? 1 : 0, 'created_at': created, 'updated_at': created,
    });
    return id;
  }

  Future<void> delete(String id) async {
    await db.exec('DELETE FROM expenses WHERE id = ?', [id]);
    await logOp(db, entity: 'expenses', entityId: id, opType: 'delete');
  }
}

final expenseRepoProvider =
    Provider<ExpenseRepository>((ref) => ExpenseRepository(ref.read(appDbProvider)));

class ReportRepository {
  final AppDatabase db;
  ReportRepository(this.db);

  /// Cash in / cash out / outstanding for a given month (1-12).
  Future<({int cashIn, int cashOut, int outstanding})> monthSummary(
      int year, int month) async {
    final prefix = '$year-${month.toString().padLeft(2, '0')}';

    final inRs = await db.rows(
        "SELECT COALESCE(SUM(p.amount),0) AS v FROM payments p "
        "WHERE substr(p.date,1,7) = ?", [prefix]);
    final outRs = await db.rows(
        "SELECT COALESCE(SUM(amount),0) AS v FROM expenses WHERE substr(date,1,7) = ?",
        [prefix]);
    final outstandRs = await db.rows(
        "SELECT COALESCE(SUM(total - IFNULL((SELECT SUM(amount) FROM payments WHERE invoice_id = i.id),0)),0) AS v "
        "FROM invoices i WHERE i.status IN ('sent','partial')");
    return (
      cashIn: inRs.first['v'] as int,
      cashOut: outRs.first['v'] as int,
      outstanding: outstandRs.first['v'] as int,
    );
  }

  /// Month-over-month revenue comparison for the AI narration.
  Future<({int thisMonth, int lastMonth})> revenueComparison() async {
    final now = DateTime.now();
    final a = await monthSummary(now.year, now.month);
    final prev = now.month == 1 ? DateTime(now.year - 1, 12) : DateTime(now.year, now.month - 1);
    final b = await monthSummary(prev.year, prev.month);
    return (thisMonth: a.cashIn, lastMonth: b.cashIn);
  }
}

final reportRepoProvider =
    Provider<ReportRepository>((ref) => ReportRepository(ref.read(appDbProvider)));
