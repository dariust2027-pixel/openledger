import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/providers.dart';
import '../data/customer_repository.dart';
import '../data/expense_repository.dart';
import '../data/invoice_repository.dart' as inv show InvoiceLineInput, InvoiceRepository;
import '../data/invoice_repository.dart' show invoiceRepoProvider;
import 'llm_provider.dart';

/// Every capability of the app, exposed once as a typed tool.
/// Adding a feature here automatically makes it voice/AI controllable.
class ActionRegistry {
  final CustomerRepository customers;
  final inv.InvoiceRepository invoices;
  final ExpenseRepository expenses;
  final AppDatabase db;

  ActionRegistry(this.customers, this.invoices, this.expenses, this.db);

  final Map<String, LlmToolDef> _defs = {};

  List<LlmToolDef> buildTools() {
    if (_defs.isNotEmpty) return _defs.values.toList();

    _defs['create_customer'] = LlmToolDef(
      'create_customer',
      'Create a customer or client record.',
      {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'email': {'type': 'string'},
          'phone': {'type': 'string'},
        },
        'required': ['name'],
      },
    );

    _defs['create_invoice'] = LlmToolDef(
      'create_invoice',
      'Create a draft invoice. Amounts are in dollars (numbers). '
          'Example: {"customer":"Acme","lines":[{"description":"Consulting","qty":3,"unit_price":90}]}',
      {
        'type': 'object',
        'properties': {
          'customer': {'type': 'string', 'description': 'existing customer name (or part of it)'},
          'lines': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'description': {'type': 'string'},
                'qty': {'type': 'number', 'default': 1},
                'unit_price': {'type': 'number', 'description': 'price per unit in dollars'},
                'tax_percent': {'type': 'number', 'default': 0},
              },
              'required': ['description', 'unit_price'],
            },
          },
          'due_date': {'type': 'string', 'description': 'ISO yyyy-MM-dd'},
          'notes': {'type': 'string'},
        },
        'required': ['customer', 'lines'],
      },
    );

    _defs['log_expense'] = LlmToolDef('log_expense',
        'Record a business expense. Amount in dollars.', {
      'type': 'object',
      'properties': {
        'amount': {'type': 'number'},
        'vendor': {'type': 'string'},
        'category': {
          'type': 'string',
          'description': 'one of: office, travel, meals, software, fuel, other'
        },
        'date': {'type': 'string', 'description': 'ISO yyyy-MM-dd; omit for today'},
        'description': {'type': 'string'},
      },
      'required': ['amount'],
    });

    _defs['list_unpaid_invoices'] = LlmToolDef(
      'list_unpaid_invoices',
      'List sent/partially paid invoices with balances.',
      {'type': 'object', 'properties': {}},
    );

    _defs['monthly_summary'] = LlmToolDef(
      'monthly_summary',
      'Revenue this month vs last month, expenses and outstanding total.',
      {'type': 'object', 'properties': {}},
    );

    _defs['find_customer'] = LlmToolDef('find_customer',
        'Look up one customer by (partial) name.', {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
      },
      'required': ['name'],
    });

    return _defs.values.toList();
  }

  /// Executes a confirmed tool call. Returns a human-readable result string.
  Future<String> execute(String name, Map<String, dynamic> args,
      {void Function(String invoiceId)? onInvoiceCreated}) async {
    switch (name) {
      case 'create_customer':
        await customers.create(
          name: args['name'] as String,
          email: args['email'] as String?,
          phone: args['phone'] as String?,
        );
        return 'Customer "${args['name']}" created.';

      case 'create_invoice':
        return _createInvoice(args, onInvoiceCreated);

      case 'log_expense':
        final amountMinor = ((args['amount'] as num) * 100).round();
        final date = args['date'] != null
            ? DateTime.parse(args['date'] as String)
            : DateTime.now();
        await expenses.create(
          amountMinor: amountMinor,
          date: date,
          vendor: args['vendor'] as String?,
          categoryId: _mapCategory(args['category'] as String?),
          description: args['description'] as String?,
        );
        return 'Expense of \$${(amountMinor / 100).toStringAsFixed(2)} logged'
            '${args['vendor'] != null ? ' for ${args['vendor']}' : ''}.';

      case 'list_unpaid_invoices':
        final list = await invoices.unpaid();
        if (list.isEmpty) return 'No unpaid invoices.';
        return list
            .map((i) => '${i['number']} — ${i['customer_name']}: '
                '\$${((i['total'] as int) / 100).toStringAsFixed(2)} (${i['status']})')
            .join('\n');

      case 'monthly_summary':
        return _monthlySummary();

      case 'find_customer':
        final c = await customers.findByName(args['name'] as String);
        if (c == null) return 'No customer found.';
        return 'Found ${c['name']}'
            '${c['email'] != null ? ' <${c['email']}>' : ''}.';

      default:
        throw ArgumentError('unknown tool: $name');
    }
  }

  Future<String> _createInvoice(Map<String, dynamic> args,
      void Function(String invoiceId)? onCreated) async {
    // Ambiguity bubbles up so the UI can ask the user to pick.
    final customer = await customers.findByName(args['customer'] as String);
    if (customer == null) {
      throw StateError('No customer named "${args['customer']}". Create them first.');
    }
    final lines = <inv.InvoiceLineInput>[];
    for (final raw in (args['lines'] as List? ?? [])) {
      final m = raw as Map<String, dynamic>;
      lines.add(inv.InvoiceLineInput(
        description: (m['description'] ?? 'Item') as String,
        qty: ((m['qty'] ?? 1) as num).toDouble(),
        unitPriceMinor: ((m['unit_price'] as num) * 100).round(),
        taxPercent: ((m['tax_percent'] ?? 0) as num).toDouble(),
      ));
    }
    final id = await invoices.create(
      customerId: customer['id'] as String,
      lines: lines,
      dueDate: args['due_date'] as String?,
      notes: args['notes'] as String?,
    );
    onCreated?.call(id);
    final total = lines.fold<int>(0, (s, l) => s + l.lineTotal);
    return 'Draft invoice created for ${customer['name']} — '
        '\$${(total / 100).toStringAsFixed(2)}, ${lines.length} line(s).';
  }

  Future<String> _monthlySummary() async {
    final now = DateTime.now();
    final cur = await _monthCash(now);
    final prevDate =
        now.month == 1 ? DateTime(now.year - 1, 12) : DateTime(now.year, now.month - 1);
    final prev = await _monthCash(prevDate);
    final outRs = await db.rows(
        'SELECT COALESCE(SUM(amount),0) AS v FROM expenses WHERE substr(date,1,7) = ?',
        ['${now.year}-${now.month.toString().padLeft(2, '0')}']);
    final outstandRs = await db.rows(
        "SELECT COALESCE(SUM(total - IFNULL((SELECT SUM(amount) FROM payments "
        "WHERE invoice_id = i.id),0)),0) AS v FROM invoices i "
        "WHERE i.status IN ('sent','partial')");
    final delta = cur - prev;
    return 'Revenue this month \$${(cur / 100).toStringAsFixed(2)} vs last month '
        '\$${(prev / 100).toStringAsFixed(2)} (${delta >= 0 ? '+' : ''}'
        '\$${(delta / 100).toStringAsFixed(2)}). '
        'Expenses \$${((outRs.first['v'] as int) / 100).toStringAsFixed(2)}. '
        'Outstanding \$${((outstandRs.first['v'] as int) / 100).toStringAsFixed(2)}.';
  }

  Future<int> _monthCash(DateTime d) async {
    final rs = await db.rows(
        'SELECT COALESCE(SUM(amount),0) AS v FROM payments WHERE substr(date,1,7) = ?',
        ['${d.year}-${d.month.toString().padLeft(2, '0')}']);
    return rs.first['v'] as int;
  }

  String? _mapCategory(String? name) {
    const map = {
      'office': 'cat-office', 'supplies': 'cat-office',
      'travel': 'cat-travel',
      'meals': 'cat-meals', 'food': 'cat-meals', 'restaurant': 'cat-meals',
      'software': 'cat-software', 'saas': 'cat-software',
      'fuel': 'cat-fuel', 'gas': 'cat-fuel',
      'other': 'cat-other',
    };
    return map[(name ?? '').toLowerCase()];
  }
}

final actionRegistryProvider = Provider<ActionRegistry>((ref) {
  return ActionRegistry(
    ref.read(customerRepoProvider),
    ref.read(invoiceRepoProvider),
    ref.read(expenseRepoProvider),
    ref.read(appDbProvider),
  );
});
