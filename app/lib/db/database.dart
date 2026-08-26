import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'schema.dart';
import 'encryption.dart';

/// Local-first database.
///
/// Uses drift's reactive engine with raw SQL + dynamic row maps
/// (`customSelect` / `customStatement`) so no code generation step is needed.
class AppDatabase extends GeneratedDatabase {
  AppDatabase() : super(_open());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 4;

  // All schema lives in raw SQL (see schema.dart); drift only provides
  // connectivity, transactions and reactive queries here.
  @override
  Iterable<TableInfo<Table, DataClass>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          // Run the full history (v1 tables + every later step) so fresh
          // installs always end up on the current schema. Each statement is
          // individually tolerant because later ALTERs may already be covered
          // by fresh-install DDL.
          final all = [
            ...Schema.statements,
            ...Schema.statementsV2,
            ...Schema.statementsV3,
            ...Schema.statementsV4,
          ];
          for (final sql in all) {
            try {
              await customStatement(sql);
            } catch (_) {
              // Idempotent: skip statements that don't apply.
            }
          }
        },
        onUpgrade: (m, from, to) async {
          final steps = <int, List<String>>{
            2: Schema.statementsV2,
            3: Schema.statementsV3,
            4: Schema.statementsV4,
          };
          for (final entry in steps.entries) {
            if (from < entry.key) {
              for (final sql in entry.value) {
                try {
                  await customStatement(sql);
                } catch (_) {
                  // Idempotent: ALTERs may already exist on partial upgrades.
                }
              }
            }
          }
        },
      );

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

  /// Stable per-device identity used to prefix document numbers so two
  /// offline devices can never mint the same number (INV-A1B2-0007 vs
  /// INV-C3D4-0001). Generated once, then persisted in settings.
  Future<String> deviceTag() async {
    final existing = await getSetting<String>('device_tag', '');
    if (existing.isNotEmpty) return existing;
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    final tag = String.fromCharCodes(
        List.generate(4, (_) => alphabet.codeUnitAt(rnd.nextInt(alphabet.length))));
    await setSetting('device_tag', tag);
    return tag;
  }
}

LazyDatabase _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'openledger.sqlite'));

    // Encrypt at rest on mobile: SQLCipher with a keystore-held key.
    // Legacy plaintext databases are migrated transparently on first open.
    String? passphrase;
    if (Platform.isAndroid || Platform.isIOS) {
      await loadSqlCipherLibrary();
      passphrase = await getOrCreateDbPassphrase();
      await migratePlaintextDatabaseIfNeeded(file, passphrase);
    }

    return NativeDatabase.createInBackground(file, setup: (rawDb) {
      if (passphrase != null) {
        rawDb.execute("PRAGMA key = '$passphrase'");
      }
    });
  });
}
