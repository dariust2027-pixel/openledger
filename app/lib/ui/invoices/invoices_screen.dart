import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../db/providers.dart';
import '../../data/invoice_repository.dart' show invoiceRepoProvider;
import '../../pdf/invoice_pdf.dart';
import 'invoice_form_sheet.dart';

class InvoicesScreen extends ConsumerWidget {
  const InvoicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invoicesAsync = ref.watch(_invoicesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Invoices')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New invoice'),
        onPressed: () => showInvoiceForm(context),
      ),
      body: invoicesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (invoices) => invoices.isEmpty
            ? const Center(child: Text('No invoices yet.\nTry the command bar on Home.'))
            : RefreshIndicator(
                onRefresh: () async => ref.invalidate(_invoicesProvider),
                child: ListView.builder(
                  itemCount: invoices.length,
                  itemBuilder: (context, i) {
                    final inv = invoices[i];
                    return _InvoiceTile(invoice: inv);
                  },
                ),
              ),
      ),
    );
  }
}

final _invoicesProvider = StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  final db = ref.watch(appDbProvider);
  return db.watchRows('SELECT i.*, c.name AS customer_name FROM invoices i '
      'LEFT JOIN customers c ON c.id = i.customer_id '
      'ORDER BY i.issue_date DESC, i.created_at DESC LIMIT 500');
});

class _InvoiceTile extends ConsumerWidget {
  final Map<String, dynamic> invoice;
  const _InvoiceTile({required this.invoice});

  Color _statusColor(BuildContext context, String status) => switch (status) {
        'paid' => Colors.green.shade600,
        'partial' => Colors.orange.shade600,
        'void' => Colors.grey,
        'sent' => Theme.of(context).colorScheme.primary,
        _ => Colors.blueGrey,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inv = invoice;
    final status = inv['status'] as String;
    final total = (inv['total'] as int) / 100;

    return ListTile(
      title: Text('${inv['number']} · ${inv['customer_name'] ?? '?'}'),
      subtitle: Text('${inv['issue_date']}'),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('\$${total.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Chip(
            label: Text(status, style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            backgroundColor: _statusColor(context, status).withValues(alpha: 0.15),
          ),
        ],
      ),
      onTap: () => _openDetails(context, ref),
    );
  }

  Future<void> _openDetails(BuildContext context, WidgetRef ref) async {
    final db = ref.read(appDbProvider);
    final lines = await db.rows(
        'SELECT * FROM invoice_lines WHERE invoice_id = ? ORDER BY position',
        [invoice['id']]);
    final paidRs = await db.rows(
        'SELECT COALESCE(SUM(amount),0) AS p FROM payments WHERE invoice_id = ?',
        [invoice['id']]);

    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          shrinkWrap: true,
          children: [
            Text('${invoice['number']} — ${invoice['customer_name']}',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Status: ${invoice['status']} · Paid: '
                '\$${((paidRs.first['p'] as int) / 100).toStringAsFixed(2)} '
                'of \$${((invoice['total'] as int) / 100).toStringAsFixed(2)}'),
            const Divider(height: 24),
            ...lines.map((d) {
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${d['description']}'),
                subtitle: Text('${d['qty']} × '
                    '\$${((d['unit_price'] as int) / 100).toStringAsFixed(2)}'),
                trailing: Text('\$${((d['line_total'] as int) / 100).toStringAsFixed(2)}'),
              );
            }),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton.icon(
                icon: const Icon(Icons.picture_as_pdf, size: 18),
                label: const Text('Export PDF'),
                onPressed: () async {
                  try {
                    final path = await exportInvoicePdf(invoice, lines);
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('PDF saved: $path')));
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Export failed: $e')));
                    }
                  }
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.payments, size: 18),
                label: const Text('Record payment'),
                onPressed: () async {
                  final amount = await _askAmount(context);
                  if (amount == null || amount <= 0) return;
                  await ref.read(invoiceRepoProvider).addPayment(
                        invoice['id'] as String,
                        (amount * 100).round(),
                      );
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Future<double?> _askAmount(BuildContext context) {
    final ctrl = TextEditingController();
    return showDialog<double>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Payment received'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(prefixText: '\$'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context,
              double.tryParse(ctrl.text.replaceAll(RegExp(r'[^0-9.]'), ''))),
              child: const Text('Save')),
        ],
      ),
    );
  }
}
