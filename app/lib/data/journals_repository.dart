import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/providers.dart';
import 'customer_repository.dart' show newId, nowMs;
import 'ops.dart';

/// Manual journal entries — the accountant's escape hatch for adjustments
/// that don't fit invoices/expenses. Every entry is double-entry: a debit
/// and a credit of equal size against two ledger categories.
class JournalRepository {
  final AppDatabase db;
  JournalRepository(this.db);

  Stream<List<Map<String, dynamic>>> watchAll() => db.watchRows(
      'SELECT j.*, dc.name AS debit_account, cc.name AS credit_account '
      'FROM journals j '
      'LEFT JOIN journal_lines dl ON dl.journal_id = j.id AND dl.side = \'debit\' '
      'LEFT JOIN categories dc ON dc.id = dl.category_id '
      'LEFT JOIN journal_lines cl ON cl.journal_id = j.id AND cl.side = \'credit\' '
      'LEFT JOIN categories cc ON cc.id = cl.category_id '
      'ORDER BY j.date DESC, j.created_at DESC LIMIT 500');

  Future<List<Map<String, dynamic>>> categories() =>
      db.rows('SELECT * FROM categories ORDER BY kind, name');

  /// Creates a balanced entry; throws if amounts disagree.
  Future<String> createEntry({
    required DateTime date,
    required String narration,
    required String debitCategoryId,
    required String creditCategoryId,
    required int amountMinor,
    String currency = 'USD',
  }) async {
    if (debitCategoryId == creditCategoryId) {
      throw ArgumentError('debit and credit accounts must differ');
    }
    if (amountMinor <= 0) throw ArgumentError('amount must be positive');

    final id = newId();
    final now = nowMs();
    final dateStr = date.toIso8601String().substring(0, 10);
    await db.transaction(() async {
      await db.exec(
        'INSERT INTO journals (id, date, narration, amount, currency, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [id, dateStr, narration, amountMinor, currency, now, now],
      );
      await db.exec(
        'INSERT INTO journal_lines (id, journal_id, category_id, side, amount) '
        'VALUES (?, ?, ?, \'debit\', ?)',
        [newId(), id, debitCategoryId, amountMinor],
      );
      await db.exec(
        'INSERT INTO journal_lines (id, journal_id, category_id, side, amount) '
        'VALUES (?, ?, ?, \'credit\', ?)',
        [newId(), id, creditCategoryId, amountMinor],
      );
      await logOp(db, entity: 'journals', entityId: id, opType: 'create', payload: {
        'id': id, 'date': dateStr, 'narration': narration,
        'amount': amountMinor, 'currency': currency,
        'debit_category_id': debitCategoryId,
        'credit_category_id': creditCategoryId,
        'created_at': now, 'updated_at': now,
      });
    });
    return id;
  }

  Future<void> delete(String id) async {
    await db.exec('DELETE FROM journal_lines WHERE journal_id = ?', [id]);
    await db.exec('DELETE FROM journals WHERE id = ?', [id]);
    await logOp(db, entity: 'journals', entityId: id, opType: 'delete');
  }
}

final journalRepoProvider =
    Provider<JournalRepository>((ref) => JournalRepository(ref.read(appDbProvider)));
