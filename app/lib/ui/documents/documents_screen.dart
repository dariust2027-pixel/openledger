import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/customer_repository.dart';
import '../../data/documents_repository.dart';
import '../../data/items_repository.dart';
import '../../data/vendors_repository.dart';
import 'doc_tile.dart';
/// One screen drives Quotes, Sales Orders, Purchase Orders and Bills —
/// the document type is the only difference (party + lifecycle actions).
class DocumentsScreen extends ConsumerWidget {
  final DocType type;
  const DocumentsScreen({super.key, required this.type});

  String get _title => switch (type) {
        DocType.quote => 'Quotes',
        DocType.salesOrder => 'Sales Orders',
        DocType.purchaseOrder => 'Purchase Orders',
        DocType.bill => 'Bills',
        DocType.challan => 'Delivery Challans',
        DocType.creditNote => 'Credit Notes',
        DocType.vendorCredit => 'Vendor Credits',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docsAsync = ref.watch(_docsProvider(type));
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: Text('New ${type.label}'),
        onPressed: () => _showForm(context, ref),
      ),
      body: docsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (docs) => docs.isEmpty
            ? Center(child: Text('No ${_title.toLowerCase()} yet.'))
            : ListView.builder(
                itemCount: docs.length,
                itemBuilder: (context, i) =>
                    DocTile(doc: docs[i], type: type),
              ),
      ),
    );
  }

  Future<void> _showForm(BuildContext context, WidgetRef ref) async {
    final parties = type.isSales
        ? await ref.read(customerRepoProvider).all()
        : await ref.read(vendorRepoProvider).all();
    final items = await ref.read(itemRepoProvider).all();
    if (!context.mounted) return;

    if (parties.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(type.isSales
              ? 'Create a customer first (drawer → Customers).'
              : 'Create a vendor first (drawer → Vendors).')));
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => _DocFormSheet(
        type: type, parties: parties, items: items),
    );
  }
}

class _DocFormSheet extends ConsumerStatefulWidget {
  final DocType type;
  final List<Map<String, dynamic>> parties;
  final List<Map<String, dynamic>> items;
  const _DocFormSheet({required this.type, required this.parties, required this.items});

  @override
  ConsumerState<_DocFormSheet> createState() => _DocFormSheetState();
}

class _DocFormSheetState extends ConsumerState<_DocFormSheet> {
  late String? _partyId = widget.parties.first['id'] as String;
  String? _selectedItemId;
  final _descCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '1');
  final _priceCtrl = TextEditingController();
  final _taxCtrl = TextEditingController(text: '0');

  @override
  Widget build(BuildContext context) {
    final t = widget.type;
    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('New ${t.label}', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _partyId,
          decoration: InputDecoration(labelText: t.isSales ? 'Customer' : 'Vendor'),
          items: [
            for (final p in widget.parties)
              DropdownMenuItem(value: p['id'] as String, child: Text(p['name'] as String)),
          ],
          onChanged: (v) => setState(() => _partyId = v),
        ),
        if (widget.items.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: _selectedItemId,
            decoration:
                const InputDecoration(labelText: 'Item (optional — adjusts stock)'),
            items: [
              const DropdownMenuItem(value: null, child: Text('— free text —')),
              for (final it in widget.items)
                DropdownMenuItem(
                    value: it['id'] as String,
                    child: Text('${it['name']} (${it['qty_on_hand']} in stock)')),
            ],
            onChanged: (v) => setState(() {
              _selectedItemId = v;
              if (v != null) {
                final it = widget.items.firstWhere((i) => i['id'] == v);
                _descCtrl.text = it['name'] as String;
                _priceCtrl.text = ((it['unit_price'] as int) / 100).toStringAsFixed(2);
              }
            }),
          ),
        TextField(controller: _descCtrl,
            decoration: const InputDecoration(labelText: 'Description *')),
        Row(children: [
          Expanded(child: TextField(
              controller: _qtyCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Qty'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(
              controller: _priceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Unit price \$'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(
              controller: _taxCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Tax %'))),
        ]),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.save, size: 18),
          label: Text('Create ${t.label}'),
          onPressed: () async {
            final price =
                double.tryParse(_priceCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''));
            final desc = _descCtrl.text.trim();
            if (desc.isEmpty || price == null || _partyId == null) return;
            await ref.read(documentRepoProvider).create(
              type: t,
              partyId: _partyId!,
              lines: [
                DocLineInput(
                  itemId: _selectedItemId,
                  description: desc,
                  qty: double.tryParse(_qtyCtrl.text) ?? 1,
                  unitPriceMinor: (price * 100).round(),
                  taxPercent: double.tryParse(_taxCtrl.text) ?? 0,
                ),
              ],
            );
            if (context.mounted) Navigator.pop(context);
          },
        ),
      ]),
    );
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _taxCtrl.dispose();
    super.dispose();
  }
}

AutoDisposeStreamProvider<List<Map<String, dynamic>>> _docsProvider(DocType type) =>
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return ref.watch(documentRepoProvider).watchByType(type);
    });