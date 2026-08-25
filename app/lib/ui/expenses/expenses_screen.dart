import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../ai/ai_settings.dart';
import '../../db/providers.dart';
import '../../scan/ocr_service.dart';
import 'image_picker_proxy.dart';
import 'expense_form_sheet.dart';

class ExpensesScreen extends ConsumerWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expensesAsync = ref.watch(_expensesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Expenses')),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'scan',
            tooltip: 'Scan receipt',
            onPressed: () => startScanFlow(context, ref),
            child: const Icon(Icons.document_scanner),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.extended(
            heroTag: 'add',
            icon: const Icon(Icons.add),
            label: const Text('New expense'),
            onPressed: () => showExpenseForm(context, ref),
          ),
        ],
      ),
      body: expensesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (items) => items.isEmpty
            ? const Center(
                child: Text('No expenses yet.\nScan a receipt or use the command bar.'))
            : ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final e = items[i];
                  final amount = (e['amount'] as int) / 100;
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(_categoryInitial(e['category_name'] as String?)),
                    ),
                    title: Text((e['vendor'] ?? e['description'] ?? 'Expense')),
                    subtitle: Text('${e['date']}'
                        '${e['category_name'] != null ? ' · ${e['category_name']}' : ''}'),
                    trailing: Text('-\$${amount.toStringAsFixed(2)}',
                        style: TextStyle(color: Colors.red.shade400, fontWeight: FontWeight.w600)),
                  );
                },
              ),
      ),
    );
  }

  String _categoryInitial(String? name) =>
      (name == null || name.isEmpty) ? '?' : name[0].toUpperCase();
}

final _expensesProvider = StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  final db = ref.watch(appDbProvider);
  return db.watchRows('SELECT e.*, c.name AS category_name FROM expenses e '
      'LEFT JOIN categories c ON c.id = e.category_id '
      'ORDER BY e.date DESC, e.created_at DESC LIMIT 500');
});

/// Scan-to-entry: pick/capture → OCR → structure → review form.
Future<void> startScanFlow(BuildContext context, WidgetRef ref) async {
  try {
    final picked = await _pickImage(context);
    if (picked == null) return;

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reading document…')));

    final ocr = ref.read(ocrServiceProvider);
    final cfg = await ref.read(aiSettingsProvider.notifier).loadConfig();
    final (doc, rawText) = await scanAndStructure(ocr, cfg, picked);

    if (!context.mounted) return;
    await showExpenseForm(context, ref,
        ocrText: rawText.isEmpty ? null : rawText,
        prefillAmount: doc?.amount,
        prefillVendor: doc?.vendor,
        prefillDate: doc?.date,
        prefillCategoryHint: doc?.categoryHint);
  } on OcrUnavailableException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      await showExpenseForm(context, ref);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Scan failed: $e')));
    }
  }
}

Future<String?> _pickImage(BuildContext context) async {
  // image_picker is imported by expense flow helper below to keep this file lean.
  return showModalBottomSheet<String>(
    context: context,
    builder: (_) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.photo_camera),
          title: const Text('Take photo'),
          onTap: () => Navigator.pop(context, 'camera'),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library),
          title: const Text('Choose from gallery'),
          onTap: () => Navigator.pop(context, 'gallery'),
        ),
      ]),
    ),
  ).then((choice) async {
    if (choice == null) return null;
    return ImagePickerProxy.pick(choice == 'camera');
  });
}
