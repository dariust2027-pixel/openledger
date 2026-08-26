import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/documents_repository.dart';
import 'accountant/journals_screen.dart';
import 'banking/banking_screen.dart';
import 'customers/customers_screen.dart';
import 'documents/documents_screen.dart';
import 'documents/inbox_screen.dart';
import 'expenses/expenses_screen.dart';
import 'home_screen.dart';
import 'invoices/invoices_screen.dart';
import 'items/items_screen.dart';
import 'payments/payments_screen.dart';
import 'reports/cogs_screen.dart';
import 'reports/reports_screen.dart';
import 'settings/settings_screen.dart';
import 'vendors/vendors_screen.dart';

class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  int _index = 0;

  static const _destinations = [
    NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
    NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Invoices'),
    NavigationDestination(icon: Icon(Icons.shopping_bag_outlined), selectedIcon: Icon(Icons.shopping_bag), label: 'Expenses'),
    NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: 'Reports'),
    NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
  ];

  static const _screens = [
    HomeScreen(),
    InvoicesScreen(),
    ExpensesScreen(),
    ReportsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    if (wide) {
      return Scaffold(
        drawer: const _ModulesDrawer(),
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              extended: MediaQuery.of(context).size.width >= 1200,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: d.icon,
                    selectedIcon: d.selectedIcon,
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _screens[_index]),
          ],
        ),
      );
    }
    return Scaffold(
      drawer: const _ModulesDrawer(),
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: _destinations,
      ),
    );
  }
}

/// Zoho-style module drawer — full module list beyond the 5 bottom tabs.
class _ModulesDrawer extends StatelessWidget {
  const _ModulesDrawer();

  @override
  Widget build(BuildContext context) {
    void go(Widget screen) {
      Navigator.pop(context); // close drawer
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    }

    return Drawer(
      child: ListView(padding: EdgeInsets.zero, children: [
        DrawerHeader(
          decoration:
              BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer),
          child: Text('OpenLedger',
              style: Theme.of(context).textTheme.headlineSmall),
        ),
        _section(context, 'Inventory', [
          ('Items', Icons.inventory_2_outlined, () => go(const ItemsScreen())),
        ]),
        _section(context, 'Sales', [
          ('Customers', Icons.people_outline, () => go(const CustomersScreen())),
          ('Quotes', Icons.request_quote_outlined,
              () => go(const DocumentsScreen(type: DocType.quote))),
          ('Sales Orders', Icons.assignment_outlined,
              () => go(const DocumentsScreen(type: DocType.salesOrder))),
          ('Delivery Challans', Icons.local_shipping_outlined,
              () => go(const DocumentsScreen(type: DocType.challan))),
          ('Invoices', Icons.receipt_long_outlined,
              () => go(const InvoicesScreen())),
          ('Payments Received', Icons.south_west,
              () => go(const PaymentsScreen(received: true))),
          ('Credit Notes', Icons.receipt,
              () => go(const DocumentsScreen(type: DocType.creditNote))),
        ]),
        _section(context, 'Purchases', [
          ('Vendors', Icons.storefront_outlined, () => go(const VendorsScreen())),
          ('Expenses', Icons.shopping_bag_outlined,
              () => go(const ExpensesScreen())),
          ('Purchase Orders', Icons.local_shipping_outlined,
              () => go(const DocumentsScreen(type: DocType.purchaseOrder))),
          ('Bills', Icons.receipt_outlined,
              () => go(const DocumentsScreen(type: DocType.bill))),
          ('Payments Made', Icons.north_east,
              () => go(const PaymentsScreen(received: false))),
          ('Vendor Credits', Icons.receipt,
              () => go(const DocumentsScreen(type: DocType.vendorCredit))),
        ]),
        _section(context, 'Accountant', [
          ('Banking', Icons.account_balance_outlined,
              () => go(const BankingScreen())),
          ('Manual Journals', Icons.balance,
              () => go(const JournalsScreen())),
          ('Inventory & COGS', Icons.trending_up,
              () => go(const CogsScreen())),
        ]),
        _section(context, 'Documents', [
          ('Inbox & Files', Icons.folder_outlined, () => go(const InboxScreen())),
        ]),
      ]),
    );
  }

  Widget _section(BuildContext context, String title,
      List<(String, IconData, VoidCallback)> entries) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall),
      ),
      for (final (label, icon, onTap) in entries)
        ListTile(leading: Icon(icon), title: Text(label), onTap: onTap),
    ]);
  }
}
