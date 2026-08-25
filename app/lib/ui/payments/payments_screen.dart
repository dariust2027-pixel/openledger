import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../db/providers.dart';
import '../../domain/currencies.dart';

/// Payments Received (sales side) and Payments Made (purchase side),
/// selectable via tabs.
class PaymentsScreen extends StatelessWidget {
  final bool received;
  const PaymentsScreen({super.key, required this.received});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: received ? 0 : 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Payments'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Received'),
            Tab(text: 'Made'),
          ]),
        ),
        body: const TabBarView(children: [_ReceivedList(), _MadeList()]),
      ),
    );
  }
}

class _ReceivedList extends ConsumerWidget {
  const _ReceivedList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(_receivedProvider);
    return rowsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (rows) => rows.isEmpty
          ? const Center(child: Text('No payments received yet.'))
          : ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final r = rows[i];
                return ListTile(
                  leading: Icon(Icons.south_west, color: Colors.green.shade600),
                  title: Text(r['customer_name'] as String? ?? 'Payment'),
                  subtitle: Text('${r['date']} · ${r['method']} · ${r['invoice_number']}'),
                  trailing: Text('+${Currencies.format(r['amount'] as int)}',
                      style: TextStyle(
                          color: Colors.green.shade600,
                          fontWeight: FontWeight.w600)),
                );
              },
            ),
    );
  }
}

class _MadeList extends ConsumerWidget {
  const _MadeList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(_madeProvider);
    return rowsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (rows) => rows.isEmpty
          ? const Center(child: Text('No payments made yet.'))
          : ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final r = rows[i];
                return ListTile(
                  leading: Icon(Icons.north_east, color: Colors.red.shade400),
                  title: Text(r['description'] as String? ?? 'Payment made'),
                  subtitle: Text('${r['date']} · ${r['method']}'),
                  trailing: Text('-${Currencies.format(r['amount'] as int)}',
                      style: TextStyle(
                          color: Colors.red.shade400,
                          fontWeight: FontWeight.w600)),
                );
              },
            ),
    );
  }
}

final _receivedProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(appDbProvider);
  return db.rows(
      'SELECT p.date, p.amount, p.method, i.number AS invoice_number, c.name AS customer_name '
      'FROM payments p '
      'LEFT JOIN invoices i ON i.id = p.invoice_id '
      'LEFT JOIN customers c ON c.id = i.customer_id '
      'WHERE p.invoice_id IS NOT NULL ORDER BY p.date DESC LIMIT 500');
});

final _madeProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(appDbProvider);
  final billPayments = await db.rows(
      "SELECT p.date, p.amount, p.method, "
      "COALESCE('Bill ' || d.number, 'Bill payment') AS description "
      'FROM payments p LEFT JOIN documents d ON d.id = p.doc_id '
      'WHERE p.doc_id IS NOT NULL ORDER BY p.date DESC LIMIT 500');
  final expenses = await db.rows(
      "SELECT date, amount, COALESCE(payment_method, 'card') AS method, "
      "COALESCE(vendor, description, 'Expense') AS description "
      'FROM expenses ORDER BY date DESC LIMIT 500');
  final all = [...billPayments, ...expenses];
  all.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
  return all;
});
