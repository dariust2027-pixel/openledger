import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/items_repository.dart';
import '../../domain/currencies.dart';

class ItemsScreen extends ConsumerWidget {
  const ItemsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(_itemsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Items')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New item'),
        onPressed: () => _showForm(context, ref),
      ),
      body: itemsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (items) => items.isEmpty
            ? const Center(child: Text('No items yet.\nAdd products or services you sell.'))
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final it = items[i];
                  final qty = (it['qty_on_hand'] as num).toDouble();
                  final low = qty <= 5;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: low ? Colors.orange.shade100 : null,
                      child: Text(((it['name'] as String?) ?? '?')[0].toUpperCase()),
                    ),
                    title: Text('${it['name']}'
                        '${it['sku'] != null ? ' · ${it['sku']}' : ''}'),
                    subtitle: Text('In stock: ${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 1)}'
                        '${low ? '  ⚠ low' : ''}'),
                    trailing: Text(Currencies.format(it['unit_price'] as int),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    onTap: () => _showForm(context, ref, existing: it),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _showForm(BuildContext context, WidgetRef ref,
      {Map<String, dynamic>? existing}) {
    final nameCtrl = TextEditingController(text: existing?['name'] as String? ?? '');
    final skuCtrl = TextEditingController(text: existing?['sku'] as String? ?? '');
    final priceCtrl = TextEditingController(
        text: existing != null
            ? ((existing['unit_price'] as int) / 100).toStringAsFixed(2)
            : '');
    final qtyCtrl = TextEditingController(
        text: existing?['qty_on_hand']?.toString() ?? '0');

    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(existing == null ? 'New item' : 'Edit item',
              style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Name *')),
          TextField(controller: skuCtrl,
              decoration: const InputDecoration(labelText: 'SKU (optional)')),
          Row(children: [
            Expanded(child: TextField(
                controller: priceCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Sale price \$'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(
                controller: qtyCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Stock qty'))),
          ]),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.save, size: 18),
            label: Text(existing == null ? 'Create item' : 'Save changes'),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final price = double.tryParse(
                  priceCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''));
              final qty = double.tryParse(qtyCtrl.text) ?? 0;
              if (name.isEmpty || price == null) return;
              final repo = ref.read(itemRepoProvider);
              if (existing == null) {
                await repo.create(name: name,
                    sku: skuCtrl.text.trim().isEmpty ? null : skuCtrl.text.trim(),
                    unitPriceMinor: (price * 100).round(), qtyOnHand: qty);
              } else {
                await repo.update(existing['id'] as String, name: name,
                    sku: skuCtrl.text.trim(),
                    unitPriceMinor: (price * 100).round(), qtyOnHand: qty);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
          ),
        ]),
      ),
    );
  }
}

final _itemsProvider = StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) =>
    ref.watch(itemRepoProvider).watchAll());
