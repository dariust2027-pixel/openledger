import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/customer_repository.dart';

class CustomersScreen extends ConsumerWidget {
  const CustomersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customersAsync = ref.watch(_customersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Customers')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New customer'),
        onPressed: () => _showForm(context, ref),
      ),
      body: customersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (customers) => customers.isEmpty
            ? const Center(child: Text('No customers yet.'))
            : ListView.builder(
                itemCount: customers.length,
                itemBuilder: (context, i) {
                  final c = customers[i];
                  return ListTile(
                    leading: CircleAvatar(
                        child: Text(((c['name'] as String?) ?? '?')[0].toUpperCase())),
                    title: Text(c['name'] as String),
                    subtitle: Text(c['email'] as String? ?? c['phone'] as String? ?? ''),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () =>
                          ref.read(customerRepoProvider).delete(c['id'] as String),
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
          Text('New customer', style: Theme.of(ctx).textTheme.titleLarge),
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
            label: const Text('Create customer'),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              await ref.read(customerRepoProvider).create(
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

final _customersProvider = StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) =>
    ref.watch(customerRepoProvider).watchAll());
