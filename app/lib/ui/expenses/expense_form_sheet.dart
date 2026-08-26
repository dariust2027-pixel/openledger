import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/expense_repository.dart';
import '../../data/receipt_store.dart';
import '../../domain/currencies.dart';
import 'image_picker_proxy.dart';

Future<void> showExpenseForm(
  BuildContext context,
  WidgetRef ref, {
  String? ocrText,
  double? prefillAmount,
  String? prefillVendor,
  DateTime? prefillDate,
  String? prefillCategoryHint,
  String? prefillReceiptPath,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => ExpenseFormSheet(
      ocrText: ocrText,
      prefillAmount: prefillAmount,
      prefillVendor: prefillVendor,
      prefillDate: prefillDate,
      prefillCategoryHint: prefillCategoryHint,
      prefillReceiptPath: prefillReceiptPath,
    ),
  );
}

class ExpenseFormSheet extends ConsumerStatefulWidget {
  final String? ocrText;
  final double? prefillAmount;
  final String? prefillVendor;
  final DateTime? prefillDate;
  final String? prefillCategoryHint;

  /// Local path of an image captured during scan-to-entry.
  final String? prefillReceiptPath;

  const ExpenseFormSheet({
    super.key,
    this.ocrText,
    this.prefillAmount,
    this.prefillVendor,
    this.prefillDate,
    this.prefillCategoryHint,
    this.prefillReceiptPath,
  });

  @override
  ConsumerState<ExpenseFormSheet> createState() => _ExpenseFormSheetState();
}

class _ExpenseFormSheetState extends ConsumerState<ExpenseFormSheet> {
  late final TextEditingController _amountCtrl;
  late final TextEditingController _vendorCtrl;
  late DateTime _date;
  late String _category;
  late String _currency;
  bool _saving = false;
  String? _receiptSourcePath; // local temp path before save
  String? _receiptPreviewPath;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController(
        text: widget.prefillAmount?.toStringAsFixed(2) ?? '');
    _vendorCtrl = TextEditingController(text: widget.prefillVendor ?? '');
    _date = widget.prefillDate ?? DateTime.now();
    _category = widget.prefillCategoryHint ?? 'other';
    _currency = 'USD';
    _receiptSourcePath = widget.prefillReceiptPath;
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    final p = _receiptSourcePath;
    if (p == null) return;
    final f = File(p);
    setState(() => _receiptPreviewPath = f.existsSync() ? p : null);
  }

  static const _categories = {
    'office': 'Office & Supplies',
    'travel': 'Travel',
    'meals': 'Meals',
    'software': 'Software',
    'fuel': 'Fuel',
    'other': 'Other',
  };

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _attachPhoto() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('Take photo'),
            onTap: () => Navigator.pop(sheetCtx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(sheetCtx, 'gallery'),
          ),
        ]),
      ),
    );
    if (choice == null) return;
    final path = await ImagePickerProxy.pick(choice == 'camera');
    if (path == null) return;
    setState(() => _receiptSourcePath = path);
    await _loadPreview();
  }

  Future<void> _save() async {
    final amount = double.tryParse(_amountCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''));
    if (amount == null || amount <= 0) return;
    setState(() => _saving = true);

    String? storedReceipt;
    final src = _receiptSourcePath;
    if (src != null && File(src).existsSync()) {
      try {
        storedReceipt = await ReceiptStore.save(src);
      } catch (_) {}
    }

    await ref.read(expenseRepoProvider).create(
          amountMinor: (amount * 100).round(),
          date: _date,
          vendor: _vendorCtrl.text.trim().isEmpty ? null : _vendorCtrl.text.trim(),
          categoryId: 'cat-${_category == 'office' ? 'office' : _category}',
          currency: _currency,
          receiptPath: storedReceipt,
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New expense', style: Theme.of(context).textTheme.titleLarge),
          if (widget.ocrText != null) ...[
            const SizedBox(height: 4),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Scanned text'),
              children: [ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(
                  child: Text(widget.ocrText!,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              )],
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _amountCtrl,
            autofocus: widget.prefillAmount == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount \$', prefixText: '\$'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _currency,
            decoration: const InputDecoration(labelText: 'Currency'),
            items: [
              for (final (code, symbol, _) in Currencies.supported)
                DropdownMenuItem(value: code, child: Text('$code ($symbol)')),
            ],
            onChanged: (v) => setState(() => _currency = v ?? 'USD'),
          ),
          TextField(
            controller: _vendorCtrl,
            decoration: const InputDecoration(labelText: 'Vendor (optional)'),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in _categories.entries)
                ChoiceChip(
                  label: Text(e.value),
                  selected: _category == e.key,
                  onSelected: (_) => setState(() => _category = e.key),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.calendar_month),
              label: Text(_date.toIso8601String().substring(0, 10)),
              onPressed: _pickDate,
            )),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: Icon(_receiptSourcePath != null
                  ? Icons.receipt_long : Icons.attach_file),
              label: Text(_receiptSourcePath != null ? 'Attached' : 'Attach'),
              onPressed: _attachPhoto,
            ),
          ]),
          if (_receiptPreviewPath != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(_receiptPreviewPath!), fit: BoxFit.cover),
                ),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: _saving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: const Text('Save expense'),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _vendorCtrl.dispose();
    super.dispose();
  }
}
