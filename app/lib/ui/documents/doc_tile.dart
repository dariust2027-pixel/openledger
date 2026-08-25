import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/documents_repository.dart';
import '../../domain/currencies.dart';

class DocTile extends ConsumerWidget {
  final Map<String, dynamic> doc;
  final DocType type;
  const DocTile({super.key, required this.doc, required this.type});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = doc['status'] as String;
    return ListTile(
      title: Text('${doc['number']} · ${doc['party_name'] ?? '?'}'),
      subtitle: Text('${doc['date']}'),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Currencies.format(doc['total'] as int,
              currency: doc['currency'] as String? ?? 'USD'),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Chip(
            label: Text(status, style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
      onTap: () => _openDetails(context, ref),
    );
  }

  Future<void> _openDetails(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(documentRepoProvider);
    final lines = await repo.lines(doc['id'] as String);
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
          Text('${doc['number']} — ${doc['party_name'] ?? ''}',
              style: Theme.of(sheetCtx).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Status: ${doc['status']} · '
              'Total ${Currencies.format(doc['total'] as int, currency: doc['currency'] as String? ?? 'USD')}'),
          const Divider(height: 24),
          for (final l in lines)
            ListTile(
              dense: true, contentPadding: EdgeInsets.zero,
              title: Text('${l['description']}'),
              subtitle: Text('${l['qty']} × '
                  '${Currencies.format(l['unit_price'] as int, currency: doc['currency'] as String? ?? 'USD')}'),
              trailing: Text(Currencies.format(l['line_total'] as int,
                  currency: doc['currency'] as String? ?? 'USD')),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (type == DocType.quote && doc['converted_doc_id'] == null)
              FilledButton.icon(
                icon: const Icon(Icons.receipt_long, size: 18),
                label: const Text('Convert to Invoice'),
                onPressed: () async {
                  try {
                    await repo.convertToInvoice(doc['id'] as String);
                    if (sheetCtx.mounted) {
                      Navigator.pop(sheetCtx);
                      ScaffoldMessenger.of(sheetCtx).showSnackBar(const SnackBar(
                          content: Text('Invoice created — stock updated.')));
                    }
                  } catch (e) {
                    if (sheetCtx.mounted) {
                      ScaffoldMessenger.of(sheetCtx)
                          .showSnackBar(SnackBar(content: Text('$e')));
                    }
                  }
                },
              ),
            if (type == DocType.salesOrder && doc['status'] == 'draft')
              FilledButton.tonal(
                onPressed: () async {
                  await repo.setStatus(doc['id'] as String, 'confirmed');
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                },
                child: const Text('Mark confirmed'),
              ),
            if (type == DocType.purchaseOrder && doc['status'] == 'draft')
              FilledButton.tonal(
                onPressed: () async {
                  await repo.setStatus(doc['id'] as String, 'sent');
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                },
                child: const Text('Mark sent'),
              ),
            if (type == DocType.bill && doc['status'] != 'paid')
              OutlinedButton.icon(
                icon: const Icon(Icons.payments, size: 18),
                label: const Text('Record payment made'),
                onPressed: () async {
                  final amount = await _askAmount(sheetCtx);
                  if (amount == null || amount <= 0) return;
                  await repo.payBill(doc['id'] as String, (amount * 100).round());
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                },
              ),
          ]),
        ]),
      ),
    );
  }

  Future<double?> _askAmount(BuildContext sheetCtx) {
    final ctrl = TextEditingController();
    return showDialog<double>(
      context: sheetCtx,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('Payment made'),
        content: TextField(
          controller: ctrl, autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(prefixText: '\$'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dlgCtx,
                double.tryParse(ctrl.text.replaceAll(RegExp(r'[^0-9.]'), ''))),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
