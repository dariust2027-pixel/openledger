import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/vendors_repository.dart';

class VendorsScreen extends ConsumerWidget {
  const VendorsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vendorsAsync = ref.watch(_vendorsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Vendors')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New vendor'),
        onPressed: () => _showForm(context, ref),
      ),
      body: vendorsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (vendors) => vendors.isEmpty
            ? const Center(child: Text('No vendors yet.\nAdd suppliers you buy from.'))
            : ListView.builder(
                itemCount: vendors.length,
                itemBuilder: (context, i) {
                  final v = vendors[i];
                  return ListTile(
                    leading: CircleAvatar(
                        child: Text(((v['name'] as String?) ?? '?')[0].toUpperCase())),
                    title: Text(v['name'] as String),
                    subtitle: Text(v['email'] as String? ?? v['phone'] as String? ?? ''),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () =>
                          ref.read(vendorRepoProvider).delete(v['id'] as String),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _showForm(BuildContext context, WidgetRef ref) {
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('New vendor', style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Name *')),
          TextField(controller: emailCtrl,
              decoration: const InputDecoration(labelText: 'Email')),
          TextField(controller: phoneCtrl,
              decoration: const InputDecoration(labelText: 'Phone')),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.save, size: 18),
            label: const Text('Create vendor'),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              await ref.read(vendorRepoProvider).create(
                    name: name,
                    email: emailCtrl.text.trim().isEmpty ? null : emailCtrl.text.trim(),
                    phone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
                  );
              if (ctx.mounted) Navigator.pop(ctx);
            },
          ),
        ]),
      ),
    );
  }
}

final _vendorsProvider = StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) =>
    ref.watch(vendorRepoProvider).watchAll());
