import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../db/providers.dart';
import '../../domain/currencies.dart';

/// Inventory & COGS: revenue vs item cost for everything sold on
/// non-draft invoices, with a per-item margin breakdown.
class CogsScreen extends ConsumerWidget {
  const CogsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(_cogsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Inventory & COGS')),
      body: rowsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rows) {
          final revenue = rows.fold<int>(0, (s, r) => s + r['revenue'] as int);
          final cogs = rows.fold<int>(0, (s, r) => s + r['cogs'] as int);
          final margin = revenue - cogs;
          final marginPct = revenue > 0 ? (margin * 100 / revenue) : 0.0;

          return ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              _card(context, 'Revenue', revenue, Colors.blue.shade600),
              const SizedBox(width: 8),
              _card(context, 'COGS', cogs, Colors.orange.shade600),
              const SizedBox(width: 8),
              _card(context, 'Margin', margin,
                  margin >= 0 ? Colors.green.shade600 : Colors.red.shade600,
                  subtitle: '${marginPct.toStringAsFixed(1)}%'),
            ]),
            const SizedBox(height: 12),
            Text('Items without a cost set show COGS of \$0 — '
                'set costs in Items to get accurate margins.',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            ...rows.map((r) {
              final rev = r['revenue'] as int;
              final cost = r['cogs'] as int;
              final m = rev - cost;
              final pct = rev > 0 ? (m * 100 / rev) : 0.0;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(r['name'] as String? ?? 'Item'),
                subtitle: Text(
                    '${_fmtQty(r['qty'])} sold · cost ${Currencies.format(cost)}'
                    ' · margin ${pct.toStringAsFixed(0)}%'),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(Currencies.format(rev),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('${m >= 0 ? '+' : ''}${Currencies.format(m)}',
                        style: TextStyle(
                            fontSize: 12,
                            color:
                                m >= 0 ? Colors.green.shade600 : Colors.red.shade400)),
                  ],
                ),
              );
            }),
            if (rows.isEmpty)
              const Center(child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('No itemized sales yet.\nLink items on invoices '
                      'to see COGS here.'))),
          ]);
        },
      ),
    );
  }

  static String _fmtQty(dynamic q) => q is num
      ? (q == q.roundToDouble() ? q.toInt().toString() : q.toStringAsFixed(2))
      : '$q';

  Widget _card(BuildContext context, String label, int minor, Color color,
      {String? subtitle}) {
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
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: color, fontWeight: FontWeight.w700)),
            ),
            if (subtitle != null)
              Text(subtitle, style: Theme.of(context).textTheme.labelSmall),
          ]),
        ),
      ),
    );
  }
}

final _cogsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final db = ref.watch(appDbProvider);
  return db.rows('''
    SELECT i.name,
           SUM(l.qty) AS qty,
           CAST(SUM(l.line_total) AS INTEGER) AS revenue,
           CAST(SUM(l.qty * IFNULL(i.cost_minor, 0)) AS INTEGER) AS cogs
    FROM invoice_lines l
    JOIN items i ON i.id = l.item_id
    JOIN invoices inv ON inv.id = l.invoice_id
    WHERE l.item_id IS NOT NULL AND inv.status NOT IN ('draft', 'cancelled')
    GROUP BY i.id
    ORDER BY revenue DESC
    LIMIT 500''');
});
