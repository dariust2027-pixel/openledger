import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/providers.dart';
import 'customer_repository.dart' show newId, nowMs;
import 'invoice_repository.dart' show InvoiceLineInput;
import 'ops.dart';

/// Recurring invoice templates. On app start (and daily), due rules generate
/// real draft invoices via [InvoiceRepository.create] — so synced devices all
/// converge on the same generated documents through the op-log.
class RecurringRule {
  final String id;
  final String customerId;
  final String description;
  final int amountMinor; // single-line invoice
  final int intervalDays; // e.g. 30 monthly-ish, 7 weekly, 365 yearly
  final int taxPercent;
  final String? nextRunDate; // ISO yyyy-MM-dd
  final bool active;

  const RecurringRule({
    required this.id,
    required this.customerId,
    required this.description,
    required this.amountMinor,
    required this.intervalDays,
    this.taxPercent = 0,
    this.nextRunDate,
    this.active = true,
  });
}

class RecurringRepository {
  final AppDatabase db;
  RecurringRepository(this.db);

  Future<void> ensureTable() => db.exec('''
    CREATE TABLE IF NOT EXISTS recurring_rules (
      id TEXT PRIMARY KEY,
      customer_id TEXT NOT NULL,
      description TEXT NOT NULL,
      amount_minor INTEGER NOT NULL,
      interval_days INTEGER NOT NULL,
      tax_percent REAL NOT NULL DEFAULT 0,
      next_run_date TEXT,
      active INTEGER NOT NULL DEFAULT 1
    )''');

  Future<List<Map<String, dynamic>>> all() async {
    await ensureTable();
    return db.rows('SELECT * FROM recurring_rules ORDER BY description');
  }

  Future<String> create(RecurringRule r) async {
    await ensureTable();
    await db.exec(
      'INSERT INTO recurring_rules (id, customer_id, description, amount_minor, '
      'interval_days, tax_percent, next_run_date, active) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [r.id, r.customerId, r.description, r.amountMinor, r.intervalDays,
       r.taxPercent, r.nextRunDate, r.active ? 1 : 0],
    );
    return r.id;
  }

  Future<void> delete(String id) async {
    await ensureTable();
    await db.exec('DELETE FROM recurring_rules WHERE id = ?', [id]);
  }

  /// Creates invoices for every due rule; returns how many were generated.
  /// Called lazily from the UI (no background service needed offline-first).
  Future<int> runDue(Future<String> Function({
          required String customerId,
          required List<InvoiceLineInput> lines,
          String? notes}) createInvoice) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final due = await db.rows(
        'SELECT * FROM recurring_rules WHERE active = 1 AND '
        '(next_run_date IS NULL OR next_run_date <= ?)', [today]);
    var created = 0;
    for (final rule in due) {
      try {
        await createInvoice(
          customerId: rule['customer_id'] as String,
          lines: [
            InvoiceLineInput(
              description: rule['description'] as String,
              qty: 1,
              unitPriceMinor: rule['amount_minor'] as int,
              taxPercent: (rule['tax_percent'] as num?)?.toDouble() ?? 0,
            ),
          ],
          notes: 'Auto-generated recurring invoice',
        );
        await _advance(rule);
        created++;
      } catch (_) {/* skip bad rule, keep processing others */}
    }
    return created;
  }

  Future<void> _advance(Map<String, dynamic> rule) async {
    final interval = rule['interval_days'] as int;
    var base = DateTime.tryParse(rule['next_run_date'] as String? ?? '') ?? DateTime.now();
    while (!base.isAfter(DateTime.now())) {
      base = base.add(Duration(days: interval));
    }
    await db.exec('UPDATE recurring_rules SET next_run_date = ? WHERE id = ?',
        [base.toIso8601String().substring(0, 10), rule['id']]);
    await logOp(db, entity: 'recurring_rules', entityId: rule['id'] as String,
        opType: 'update', payload: {'next_run_date': base.toIso8601String().substring(0, 10)});
  }

  String newRuleId() => newId();
  int now() => nowMs();
}

final recurringRepoProvider =
    Provider<RecurringRepository>((ref) => RecurringRepository(ref.read(appDbProvider)));
