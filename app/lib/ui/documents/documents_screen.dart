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
  final List<_LineData> _lines = [_LineData()];

  int get _totalMinor => _lines.fold(0, (sum, l) {
        final price =
            double.tryParse(l.price.text.replaceAll(RegExp(r'[^0-9.]'), ''));
        if (price == null) return sum;
        final qty = double.tryParse(l.qty.text) ?? 1;
        final tax = double.tryParse(l.tax.text) ?? 0;
        final sub = (qty * price * 100).round();
        return sum + sub + (sub * tax / 100).round();
      });

  @override
  Widget build(BuildContext context) {
    final t = widget.type;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.88,
      child: Padding(
        padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: _lines.length,
              itemBuilder: (context, i) => _lineCard(context, i),
            ),
          ),
          Row(children: [
            TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add line'),
              onPressed: () => setState(() => _lines.add(_LineData())),
            ),
            const Spacer(),
            Text('Total  \$${(_totalMinor / 100).toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.titleMedium),
          ]),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.save, size: 18),
            label: Text('Create ${t.label}'),
            onPressed: () => _create(context),
          ),
        ]),
      ),
    );
  }

  Widget _lineCard(BuildContext context, int i) {
    final l = _lines[i];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(children: [
          Row(children: [
            Expanded(child: TextField(
                controller: l.desc,
                decoration:
                    InputDecoration(labelText: 'Description #${i + 1} *'))),
            if (widget.items.isNotEmpty)
              IconButton(
                tooltip: 'Link an item',
                icon: Icon(l.itemId != null ? Icons.inventory_2 : Icons.inventory_2_outlined,
                    color: l.itemId != null
                        ? Theme.of(context).colorScheme.primary
                        : null),
                onPressed: () => _pickItem(context, l),
              ),
            IconButton(
              tooltip: 'Remove line',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() {
                // keep at least one line
                if (_lines.length > 1) {
                  l.dispose();
                  _lines.removeAt(i);
                }
              }),
            ),
          ]),
          Row(children: [
            Expanded(child: TextField(
                controller: l.qty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Qty'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(
                controller: l.price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Unit price \$'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(
                controller: l.tax,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Tax %'))),
          ]),
          if (l.itemId != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Align(alignment: Alignment.centerLeft, child: Text(
                  '${l.itemName} · stock adjusts on create',
                  style: Theme.of(context).textTheme.bodySmall)),
            ),
        ]),
      ),
    );
  }

  Future<void> _pickItem(BuildContext context, _LineData l) async {
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dlgCtx) => SimpleDialog(
        title: const Text('Choose item'),
        children: [
          for (final it in widget.items)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dlgCtx, it),
              child: Text('${it['name']} — '
                  '\$${((it['unit_price'] as int) / 100).toStringAsFixed(2)}, '
                  '${it['qty_on_hand']} in stock'),
            ),
        ],
      ),
    );
    if (picked != null) {
      setState(() {
        l.itemId = picked['id'] as String?;
        l.itemName = picked['name'] as String?;
        l.desc.text = picked['name'] as String;
        l.price.text = ((picked['unit_price'] as int) / 100).toStringAsFixed(2);
      });
    }
  }

  Future<void> _create(BuildContext context) async {
    final inputs = <DocLineInput>[];
    for (final l in _lines) {
      final desc = l.desc.text.trim();
      final price =
          double.tryParse(l.price.text.replaceAll(RegExp(r'[^0-9.]'), ''));
      if (desc.isEmpty || price == null) continue; // skip empty/partial lines
      inputs.add(DocLineInput(
        itemId: l.itemId,
        description: desc,
        qty: double.tryParse(l.qty.text) ?? 1,
        unitPriceMinor: (price * 100).round(),
        taxPercent: double.tryParse(l.tax.text) ?? 0,
      ));
    }
    if (inputs.isEmpty || _partyId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Add at least one complete line '
              '(description + unit price).')));
      return;
    }
    await ref.read(documentRepoProvider).create(
          type: widget.type,
          partyId: _partyId!,
          lines: inputs,
        );
    if (context.mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }
}

class _LineData {
  String? itemId;
  String? itemName;
  final desc = TextEditingController();
  final qty = TextEditingController(text: '1');
  final price = TextEditingController();
  final tax = TextEditingController(text: '0');

  void dispose() {
    desc.dispose();
    qty.dispose();
    price.dispose();
    tax.dispose();
  }
}

AutoDisposeStreamProvider<List<Map<String, dynamic>>> _docsProvider(DocType type) =>
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      return ref.watch(documentRepoProvider).watchByType(type);
    });