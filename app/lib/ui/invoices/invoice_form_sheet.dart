import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/customer_repository.dart';
import '../../data/invoice_repository.dart';
import '../../domain/currencies.dart';

Future<void> showInvoiceForm(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const InvoiceFormSheet(),
  );
}

class InvoiceFormSheet extends ConsumerStatefulWidget {
  const InvoiceFormSheet({super.key});

  @override
  ConsumerState<InvoiceFormSheet> createState() => _InvoiceFormSheetState();
}

class _InvoiceFormSheetState extends ConsumerState<InvoiceFormSheet> {
  final _customerCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '1');
  final _priceCtrl = TextEditingController();
  final _taxCtrl = TextEditingController(text: '0');

  Map<String, dynamic>? _selectedCustomer;
  List<Map<String, dynamic>> _suggestions = [];
  final List<InvoiceLineInput> _lines = [];
  String? _error;
  String _currency = 'USD';

  static const _currencyCodes = Currencies.supported;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New invoice', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _currency,
              decoration: const InputDecoration(labelText: 'Currency'),
              items: [
                for (final (code, symbol, _) in _currencyCodes)
                  DropdownMenuItem(value: code, child: Text('$code ($symbol)')),
              ],
              onChanged: (v) => setState(() => _currency = v ?? 'USD'),
            ),
            Autocomplete<Map<String, dynamic>>(
              displayStringForOption: (c) => c['name'] as String,
              fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
                controller: ctrl,
                focusNode: focus,
                decoration: const InputDecoration(labelText: 'Customer'),
                onChanged: (v) => _suggest(v),
              ),
              optionsBuilder: (_) => _suggestions,
              onSelected: (c) => setState(() => _selectedCustomer = c),
            ),
            if (_selectedCustomer != null)
              Align(alignment: Alignment.centerLeft,
                  child: Text('✓ ${_selectedCustomer!['name']}',
                      style: const TextStyle(color: Colors.green))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(flex: 3, child: TextField(
                  controller: _descCtrl,
                  decoration: const InputDecoration(labelText: 'Description'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(
                  controller: _qtyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Qty'))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(
                  controller: _priceCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Unit price \$'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(
                  controller: _taxCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Tax %'))),
              IconButton.filledTonal(
                tooltip: 'Add line',
                icon: const Icon(Icons.add),
                onPressed: _addLine,
              ),
            ]),
            const SizedBox(height: 8),
            ..._lines.map((l) => ListTile(
                  dense: true,
                  title: Text(l.description),
                  subtitle: Text('${l.qty} × '
                      '\$${(l.unitPriceMinor / 100).toStringAsFixed(2)}'
                      '${l.taxPercent > 0 ? ' + ${l.taxPercent}% tax' : ''}'),
                  trailing: Text('\$${(l.lineTotal / 100).toStringAsFixed(2)}'),
                )),
            if (_lines.isNotEmpty)
              Align(alignment: Alignment.centerRight,
                  child: Text('Total: \$${(_total() / 100).toStringAsFixed(2)}',
                      style: Theme.of(context).textTheme.titleMedium)),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.save),
              label: const Text('Create draft invoice'),
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _suggest(String q) async {
    if (q.trim().length < 2 || _selectedCustomer?['name'] == q) {
      setState(() => _suggestions = []);
      return;
    }
    final all = await ref.read(customerRepoProvider).all();
    setState(() {
      _suggestions = all
          .where((c) => (c['name'] as String).toLowerCase().contains(q.toLowerCase()))
          .take(5)
          .toList();
      _selectedCustomer = null;
    });
  }

  void _addLine() {
    final price = double.tryParse(_priceCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''));
    final qty = double.tryParse(_qtyCtrl.text) ?? 1;
    final tax = double.tryParse(_taxCtrl.text) ?? 0;
    if (_descCtrl.text.trim().isEmpty || price == null) {
      setState(() => _error = 'Line needs a description and a valid price.');
      return;
    }
    setState(() {
      _lines.add(InvoiceLineInput(
        description: _descCtrl.text.trim(),
        qty: qty,
        unitPriceMinor: (price * 100).round(),
        taxPercent: tax,
      ));
      _descCtrl.clear();
      _priceCtrl.clear();
      _qtyCtrl.text = '1';
      _error = null;
    });
  }

  int _total() => _lines.fold(0, (s, l) => s + l.lineTotal);

  Future<void> _save() async {
    if (_selectedCustomer == null) {
      setState(() => _error = 'Pick an existing customer.');
      return;
    }
    if (_lines.isEmpty) {
      setState(() => _error = 'Add at least one line.');
      return;
    }
    try {
      await ref.read(invoiceRepoProvider).create(
            customerId: _selectedCustomer!['id'] as String,
            lines: _lines,
            currency: _currency,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _customerCtrl.dispose();
    _descCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    _taxCtrl.dispose();
    super.dispose();
  }
}
