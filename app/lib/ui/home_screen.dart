import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../ai/assistant_controller.dart';
import '../data/invoice_repository.dart' show invoiceRepoProvider;
import '../data/recurring_repository.dart';
import '../db/providers.dart';
import 'command_bar.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Generate any due recurring invoices once per app start.
    Future.microtask(() async {
      try {
        final recurring = ref.read(recurringRepoProvider);
        final invoices = ref.read(invoiceRepoProvider);
        await recurring.runDue(
          ({required customerId, required lines, notes}) =>
              invoices.create(customerId: customerId, lines: lines, notes: notes),
        );
      } catch (_) {/* never block startup */}
    });
  }

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(_monthSummaryProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const CommandBar(),
          const SizedBox(height: 16),
          Text('This month', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          summaryAsync.when(
            loading: () => const Center(child: Padding(
              padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
            error: (e, _) => Card(child: ListTile(title: Text('Error: $e'))),
            data: (({int cashIn, int cashOut, int outstanding}) s) => Column(children: [
              _GlanceCard(
                icon: Icons.trending_up,
                color: Colors.green.shade600,
                label: 'Cash in',
                value: _fmt(s.cashIn),
              ),
              const SizedBox(height: 8),
              _GlanceCard(
                icon: Icons.trending_down,
                color: Colors.red.shade400,
                label: 'Cash out',
                value: _fmt(s.cashOut),
              ),
              const SizedBox(height: 8),
              _GlanceCard(
                icon: Icons.hourglass_top,
                color: Theme.of(context).colorScheme.primary,
                label: 'Outstanding',
                value: _fmt(s.outstanding),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          const _RecentDraftCard(),
        ],
      ),
    );
  }

  static String _fmt(int minor) {
    final v = minor / 100;
    return '\$${v.toStringAsFixed(2)}';
  }
}

class _GlanceCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;

  const _GlanceCard({required this.icon, required this.color, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon, color: color, size: 28),
        title: Text(label, style: Theme.of(context).textTheme.bodySmall),
        subtitle: Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// Shows the latest AI draft awaiting confirmation.
class _RecentDraftCard extends ConsumerWidget {
  const _RecentDraftCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(assistantProvider).value;
    if (draft == null || draft.status != DraftStatus.pending) return const SizedBox.shrink();
    return ConfirmationCard(draft: draft);
  }
}

final _monthSummaryProvider = FutureProvider.autoDispose<
    ({int cashIn, int cashOut, int outstanding})>((ref) async {
  final db = ref.watch(appDbProvider);
  final now = DateTime.now();
  final prefix = '${now.year}-${now.month.toString().padLeft(2, '0')}';
  final inRs = await db.rows(
      'SELECT COALESCE(SUM(amount),0) AS v FROM payments WHERE substr(date,1,7) = ?',
      [prefix]);
  final outRs = await db.rows(
      'SELECT COALESCE(SUM(amount),0) AS v FROM expenses WHERE substr(date,1,7) = ?',
      [prefix]);
  final outRs3 = await db.rows(
      "SELECT COALESCE(SUM(total - IFNULL((SELECT SUM(amount) FROM payments "
      "WHERE invoice_id = i.id),0)),0) AS v FROM invoices i "
      "WHERE i.status IN ('sent','partial')");
  return (
    cashIn: inRs.first['v'] as int,
    cashOut: outRs.first['v'] as int,
    outstanding: outRs3.first['v'] as int,
  );
});
