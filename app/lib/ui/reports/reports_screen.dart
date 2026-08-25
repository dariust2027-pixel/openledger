import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/expense_repository.dart';

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final summary =
        ref.watch(_summaryProvider((now.year, now.month)));

    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: summary.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (s) {
          final net = s.cashIn - s.cashOut;
          return ListView(padding: const EdgeInsets.all(16), children: [
            _reportCard(context, 'Cash in', s.cashIn, Icons.south_west, Colors.green.shade600),
            _reportCard(context, 'Cash out', s.cashOut, Icons.north_east, Colors.red.shade400),
            _reportCard(context, 'Net', net, Icons.balance,
                net >= 0 ? Colors.green.shade600 : Colors.red.shade400),
            _reportCard(context, 'Outstanding invoices', s.outstanding,
                Icons.hourglass_top, Colors.orange.shade600),
          ]);
        },
      ),
    );
  }

  Widget _reportCard(BuildContext context, String label, int minor, IconData icon, Color color) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color, size: 30),
        title: Text(label),
        trailing: Text('\$${(minor / 100).toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.headlineSmall),
      ),
    );
  }
}

typedef MonthKey = (int, int);

final _summaryProvider = FutureProvider.autoDispose
    .family<({int cashIn, int cashOut, int outstanding}), MonthKey>((ref, key) {
  return ref.watch(reportRepoProvider).monthSummary(key.$1, key.$2);
});
