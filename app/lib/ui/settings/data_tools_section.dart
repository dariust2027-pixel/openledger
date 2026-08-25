import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/backup_service.dart';
import '../../data/customer_repository.dart' show customerRepoProvider;
import '../../data/invoice_repository.dart' show invoiceRepoProvider;
import '../../data/recurring_repository.dart';

/// Phase-6 data tools: backup/export/import + recurring invoice manager.
class DataToolsSection extends ConsumerStatefulWidget {
  const DataToolsSection({super.key});

  @override
  ConsumerState<DataToolsSection> createState() => _DataToolsSectionState();
}

class _DataToolsSectionState extends ConsumerState<DataToolsSection> {
  List<Map<String, dynamic>> _rules = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reloadRules();
  }

  Future<void> _reloadRules() async {
    final rules = await ref.read(recurringRepoProvider).all();
    if (mounted) setState(() => _rules = rules);
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final path = await ref
          .read(backupServiceProvider)
          .exportToFile();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Backup saved: $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Export failed: $e')));
      }
    }
    setState(() => _busy = false);
  }

  Future<void> _import() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Restore backup?'),
        content: const Text('This REPLACES everything currently on this '
            'device with the contents of the backup file.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final file = await openFile();
      if (file == null) return;
      setState(() => _busy = true);
      final counts = await ref.read(backupServiceProvider).importFromFile(file.path);
      if (mounted) {
        final total = counts.values.fold(0, (a, b) => a + b);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Restored $total rows.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Import failed: $e')));
      }
    }
    setState(() => _busy = false);
  }

  Future<void> _addRule() async {
    final customers = await ref.read(customerRepoProvider).all();
    if (!mounted) return;
    if (customers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Create a customer first.')));
      return;
    }
    String? customerId = customers.first['id'] as String;
    final descCtrl = TextEditingController();
    final amountCtrl = TextEditingController();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          Text('New recurring invoice',
              style: Theme.of(sheetCtx).textTheme.titleLarge),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: customerId,
            items: [
              for (final c in customers)
                DropdownMenuItem(value: c['id'] as String,
                    child: Text(c['name'] as String)),
            ],
            onChanged: (v) => customerId = v,
            decoration: const InputDecoration(labelText: 'Customer'),
          ),
          TextField(controller: descCtrl,
              decoration: const InputDecoration(labelText: 'Description')),
          TextField(controller: amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Amount per cycle \$')),
          const SizedBox(height: 8),
          const Text('Repeats every 30 days. More intervals in a future update.',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.repeat, size: 18),
            label: const Text('Create rule'),
            onPressed: () async {
              final amount =
                  double.tryParse(amountCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''));
              if (amount == null || amount <= 0 || descCtrl.text.trim().isEmpty) return;
              final repo = ref.read(recurringRepoProvider);
              await repo.create(RecurringRule(
                id: repo.newRuleId(),
                customerId: customerId!,
                description: descCtrl.text.trim(),
                amountMinor: (amount * 100).round(),
                intervalDays: 30,
                nextRunDate: DateTime.now().toIso8601String().substring(0, 10),
              ));
              if (sheetCtx.mounted) Navigator.pop(sheetCtx);
              await _runDueAndReload();
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _runDueAndReload() async {
    final recurring = ref.read(recurringRepoProvider);
    final invoices = ref.read(invoiceRepoProvider);
    final created = await recurring.runDue(
      ({required customerId, required lines, notes}) =>
          invoices.create(customerId: customerId, lines: lines, notes: notes),
    );
    await _reloadRules();
    if (mounted && created > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Generated $created recurring invoice(s).')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(
          icon: _busy
              ? const SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.download, size: 18),
          label: const Text('Export backup'),
          onPressed: _busy ? null : _export,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.upload, size: 18),
          label: const Text('Restore'),
          onPressed: _busy ? null : _import,
        ),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.repeat, size: 18),
          label: const Text('New recurring invoice'),
          onPressed: _busy ? null : _addRule,
        ),
      ]),
      if (_rules.isNotEmpty) ...[
        const SizedBox(height: 8),
        for (final r in _rules)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.repeat),
            title: Text('${r['description']} · every ${r['interval_days']}d'),
            subtitle: Text('next: ${r['next_run_date'] ?? 'on next launch'}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await ref.read(recurringRepoProvider).delete(r['id'] as String);
                await _reloadRules();
              },
            ),
          ),
      ],
      const SizedBox(height: 4),
      Text('Due recurring invoices are generated when you open this screen '
          '(and on app start).', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
