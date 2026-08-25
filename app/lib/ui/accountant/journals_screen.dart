import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/journals_repository.dart';
import '../../domain/currencies.dart';

class JournalsScreen extends ConsumerWidget {
  const JournalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final journalsAsync = ref.watch(_journalsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Manual Journals')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New entry'),
        onPressed: () => _showForm(context, ref),
      ),
      body: journalsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (items) => items.isEmpty
            ? const Center(
                child: Text('No journal entries.\nUse them for adjustments '
                    'that are not invoices or expenses.'))
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final j = items[i];
                  return ListTile(
                    leading: const Icon(Icons.balance),
                    title: Text(j['narration'] as String? ?? ''),
                    subtitle: Text('${j['date']} · '
                        'Dr ${j['debit_account'] ?? '?'} / '
                        'Cr ${j['credit_account'] ?? '?'}'),
                    trailing: Text(Currencies.format(j['amount'] as int,
                        currency: j['currency'] as String? ?? 'USD')),
                    onTap: () => _confirmDelete(context, ref, j),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref,
      Map<String, dynamic> j) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete entry?'),
        content: Text('Remove "${j['narration']}" (${j['date']})?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(journalRepoProvider).delete(j['id'] as String);
    }
  }

  Future<void> _showForm(BuildContext context, WidgetRef ref) async {
    final cats = await ref.read(journalRepoProvider).categories();
    if (!context.mounted) return;

    String? debit = cats.firstOrNull?['id'] as String?;
    String? credit = cats.length > 1 ? cats[1]['id'] as String : debit;
    final amountCtrl = TextEditingController();
    final narrationCtrl = TextEditingController();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => Padding(
          padding: EdgeInsets.only(
              left: 16, right: 16, top: 16,
              bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16),
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('New journal entry', style: Theme.of(sheetCtx).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Move an amount from one account (credit) to another (debit).',
                style: Theme.of(sheetCtx).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(controller: narrationCtrl,
                decoration: const InputDecoration(labelText: 'Narration *')),
            TextField(controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount \$ *')),
            DropdownButtonFormField<String>(
              initialValue: debit,
              decoration: const InputDecoration(labelText: 'Debit account (to)'),
              items: [for (final c in cats)
                DropdownMenuItem(value: c['id'] as String,
                    child: Text('${c['name']} (${c['kind']})'))],
              onChanged: (v) => setSheetState(() => debit = v),
            ),
            DropdownButtonFormField<String>(
              initialValue: credit,
              decoration: const InputDecoration(labelText: 'Credit account (from)'),
              items: [for (final c in cats)
                DropdownMenuItem(value: c['id'] as String,
                    child: Text('${c['name']} (${c['kind']})'))],
              onChanged: (v) => setSheetState(() => credit = v),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.save, size: 18),
              label: const Text('Record entry'),
              onPressed: () async {
                final amount =
                    double.tryParse(amountCtrl.text.replaceAll(RegExp(r'[^0-9.]'), ''));
                final narration = narrationCtrl.text.trim();
                final debitId = debit;
                final creditId = credit;
                if (narration.isEmpty || amount == null || debitId == null || creditId == null) {
                  return;
                }
                try {
                  await ref.read(journalRepoProvider).createEntry(
                        date: DateTime.now(),
                        narration: narration,
                        debitCategoryId: debitId,
                        creditCategoryId: creditId,
                        amountMinor: (amount * 100).round(),
                      );
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                } catch (e) {
                  if (sheetCtx.mounted) {
                    ScaffoldMessenger.of(sheetCtx)
                        .showSnackBar(SnackBar(content: Text('$e')));
                  }
                }
              },
            ),
          ]),
        ),
      ),
    );
  }
}

final _journalsProvider = StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) =>
    ref.watch(journalRepoProvider).watchAll());
