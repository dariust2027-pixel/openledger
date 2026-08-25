import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../db/providers.dart';
import '../../domain/currencies.dart';

/// Banking: balances across payment methods + the full money-movement
/// ledger (payments received on invoices, bill payments, expenses).
class BankingScreen extends ConsumerWidget {
  const BankingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledgerAsync = ref.watch(_ledgerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Banking')),
      body: ledgerAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rows) {
          var balance = 0;
          final entries = <Map<String, dynamic>>[];
          for (final r in rows) {
            balance += (r['amount'] as int) * (r['direction'] as String == 'in' ? 1 : -1);
            entries.add({...r, 'running': balance});
          }
          final totalIn = rows.where((r) => r['direction'] == 'in')
              .fold(0, (s, r) => s + r['amount'] as int);
          final totalOut = rows.where((r) => r['direction'] == 'out')
              .fold(0, (s, r) => s + r['amount'] as int);

          return ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              _balanceCard(context, 'Money In', totalIn, Colors.green.shade600),
              const SizedBox(width: 8),
              _balanceCard(context, 'Money Out', totalOut, Colors.red.shade400),
              const SizedBox(width: 8),
              _balanceCard(context, 'Balance', balance,
                  balance >= 0 ? Colors.blue.shade600 : Colors.red.shade600),
            ]),
            const SizedBox(height: 12),
            Text('All transactions', style: Theme.of(context).textTheme.titleMedium),
            for (final e in entries)
              ListTile(
                dense: true,
                leading: Icon(
                  e['direction'] == 'in' ? Icons.south_west : Icons.north_east,
                  color: e['direction'] == 'in'
                      ? Colors.green.shade600
                      : Colors.red.shade400,
                ),
                title: Text('${e['description']}'),
                subtitle: Text('${e['date']} · ${e['source']}'),
                trailing: Text(
                  '${e['direction'] == 'in' ? '+' : '-'}'
                  '${Currencies.format(e['amount'] as int)}',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: e['direction'] == 'in'
                          ? Colors.green.shade600
                          : Colors.red.shade400),
                ),
              ),
          ]);
        },
      ),
    );
  }

  Widget _balanceCard(BuildContext context, String label, int minor, Color color) {
    return Expanded(
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Column(children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            FittedBox(
              child: Text(Currencies.format(minor),
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(color: color, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Unified ledger: invoice payments (in) + bill payments and expenses (out).
final _ledgerProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(appDbProvider);
  final ins = await db.rows(
      "SELECT p.date, p.amount, 'in' AS direction, "
      "COALESCE('Payment: ' || c.name, 'Payment received') AS description, "
      "'invoice payment' AS source "
      'FROM payments p LEFT JOIN invoices i ON i.id = p.invoice_id '
      'LEFT JOIN customers c ON c.id = i.customer_id '
      'WHERE p.invoice_id IS NOT NULL');
  final billOut = await db.rows(
      "SELECT p.date, p.amount, 'out' AS direction, "
      "COALESCE('Bill: ' || d.number, 'Bill payment') AS description, "
      "'bill payment' AS source "
      'FROM payments p LEFT JOIN documents d ON d.id = p.doc_id '
      'WHERE p.doc_id IS NOT NULL');
  final expOut = await db.rows(
      "SELECT date, amount, 'out' AS direction, "
      "COALESCE(vendor, description, 'Expense') AS description, "
      "'expense' AS source FROM expenses");
  final all = [...ins, ...billOut, ...expOut];
  all.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
  return all.reversed.toList();
});
