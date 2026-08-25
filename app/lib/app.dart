import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'theme/theme.dart';
import 'ui/root_shell.dart';

class OpenLedgerApp extends ConsumerWidget {
  const OpenLedgerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ts = ref.watch(themeControllerProvider);
    return MaterialApp(
      title: 'OpenLedger',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(ts, Brightness.light),
      darkTheme: buildAppTheme(ts, Brightness.dark),
      themeMode: switch (ts.mode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark || AppThemeMode.amoled => ThemeMode.dark,
      },
      home: const RootShell(),
    );
  }
}
