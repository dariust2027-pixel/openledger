import '../data/customer_repository.dart';
import 'action_registry.dart';

/// Offline fallback: deterministic regex commands so the app stays
/// AI-usable with no network, no API key, no cloud.
class RulesEngine {
  final ActionRegistry registry;
  final CustomerRepository customers;
  RulesEngine(this.registry, this.customers);

  /// Returns null when the utterance matches no known pattern.
  ({String tool, Map<String, dynamic> args})? match(String input) {
    final t = input.trim().toLowerCase();

    // "add expense 42 fuel" / "log 12.50 for meals at joe's"
    final exp = RegExp(
        r'^(?:add|log|record)\s+(?:expense\s+)?\$?(\d+(?:\.\d{1,2})?)(?:\s*(?:for|on|at)?\s*'
        r'(fuel|gas|meals?|food|travel|software|office.*?|other))?(?:\s+(?:for|at)\s+(.+))?$');
    final m = exp.firstMatch(t);
    if (m != null) {
      return (
        tool: 'log_expense',
        args: {
          'amount': double.parse(m.group(1)!),
          if (m.group(2) != null) 'category': _normCategory(m.group(2)!),
          if (m.group(3) != null) 'vendor': m.group(3),
        },
      );
    }

    // "unpaid invoices" / "who owes me"
    if (t.contains('owe') || t.contains('unpaid') || t.contains('outstanding')) {
      return (tool: 'list_unpaid_invoices', args: {});
    }

    // "monthly summary" / "how did this month compare"
    if (t.contains('this month') || t.contains('summary') || t.contains('compare')) {
      return (tool: 'monthly_summary', args: {});
    }

    // "new customer acme" / "create customer Acme Corp"
    final cust = RegExp(r'^(?:new|create|add)\s+customer\s+(.+)$').firstMatch(t);
    if (cust != null) {
      return (tool: 'create_customer', args: {'name': _titleCase(cust.group(1)!)});
    }

    return null;
  }

  String _normCategory(String raw) {
    final r = raw.trim();
    if (r.startsWith('fuel') || r.startsWith('gas')) return 'fuel';
    if (r.startsWith('meal') || r == 'food' || r.startsWith('food')) return 'meals';
    if (r.startsWith('travel')) return 'travel';
    if (r.startsWith('software')) return 'software';
    if (r.startsWith('office')) return 'office';
    return 'other';
  }

  String _titleCase(String s) => s
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
