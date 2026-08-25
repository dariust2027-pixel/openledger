import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'schema.dart';

/// Local-first database.
///
/// Uses drift's reactive engine with raw SQL + dynamic row maps
/// (`customSelect` / `customStatement`) so no code generation step is needed.
class AppDatabase extends GeneratedDatabase {
  AppDatabase() : super(_open());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;

  // All schema lives in raw SQL (see schema.dart); drift only provides
  // connectivity, transactions and reactive queries here.
  @override
  Iterable<TableInfo<Table, DataClass>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(onCreate: (m) async {
        for (final sql in Schema.statements) {
          await customStatement(sql);
        }
      });

  Future<T> getSetting<T>(String key, T fallback) async {
    final row = await customSelect(
      'SELECT value FROM settings WHERE key = ?',
      variables: [Variable(key)],
    ).getSingleOrNull();
    if (row == null) return fallback;
    return row.data['value'] as T? ?? fallback;
  }

  Future<void> setSetting(String key, String value) async {
    await customStatement(
      'INSERT INTO settings (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  /// Watch a SQL query reactively (used by UI lists).
  Stream<List<Map<String, dynamic>>> watchRows(String sql,
      [List<Object?> args = const []]) {
    return customSelect(sql, variables: [for (final a in args) Variable(a)])
        .watch()
        .map((rows) => rows.map((r) => r.data).toList());
  }

  Future<List<Map<String, dynamic>>> rows(String sql,
      [List<Object?> args = const []]) async {
    final rs =
        await customSelect(sql, variables: [for (final a in args) Variable(a)]).get();
    return rs.map((r) => r.data).toList();
  }

  Future<void> exec(String sql, [List<Object?> args = const []]) =>
      customStatement(sql, args);
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = p.join(dir.path, 'openledger.sqlite');
    return NativeDatabase.createInBackground(File(file));
  });
}
