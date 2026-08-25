import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import '../db/providers.dart';

/// Full backup as a single JSON archive: every table dumped and restored.
/// Restoring replaces local data wholesale — the UI must confirm first.
class BackupService {
  final AppDatabase db;
  BackupService(this.db);

  static const _tables = [
    'customers', 'items', 'tax_rates', 'categories', 'invoices',
    'invoice_lines', 'expenses', 'payments', 'settings', 'ai_actions_log',
    'recurring_rules',
  ];

  Future<String> exportToFile() async {
    final dump = <String, List<Map<String, dynamic>>>{};
    for (final t in _tables) {
      try {
        dump[t] = await db.rows('SELECT * FROM $t');
      } catch (_) {
        dump[t] = []; // table may not exist yet (fresh schema)
      }
    }
    final archive = jsonEncode({
      'format': 'openledger-backup',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'data': dump,
    });

    final dir = await _bestDir();
    final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
    final path = '${dir.path}${Platform.pathSeparator}openledger-backup-$stamp.json';
    await File(path).writeAsString(archive);
    return path;
  }

  /// Returns counts of restored rows per table.
  Future<Map<String, int>> importFromFile(String path,
      {bool wipeFirst = true}) async {
    final raw = await File(path).readAsString();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    if (decoded['format'] != 'openledger-backup') {
      throw const FormatException('Not an OpenLedger backup file');
    }
    final data = (decoded['data'] as Map).cast<String, dynamic>();

    final counts = <String, int>{};
    await db.transaction(() async {
      if (wipeFirst) {
        for (final t in _tables.reversed) {
          // children before parents to respect FKs
          try { await db.exec('DELETE FROM $t'); } catch (_) {}
        }
      }
      for (final t in _tables) {
        final rows = data[t];
        if (rows is! List || rows.isEmpty) continue;
        var n = 0;
        for (final row in rows) {
          final m = (row as Map).cast<String, dynamic>();
          final cols = m.keys.toList();
          try {
            await db.exec(
              'INSERT OR REPLACE INTO $t (${cols.join(',')}) '
              'VALUES (${cols.map((_) => '?').join(',')})',
              [for (final c in cols) m[c]],
            );
            n++;
          } catch (_) {/* skip malformed rows */}
        }
        counts[t] = n;
      }
    });
    return counts;
  }

  Future<Directory> _bestDir() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } catch (_) {}
    return getApplicationDocumentsDirectory();
  }
}

abstract class Database {
  Future<List<Map<String, dynamic>>> rows(String sql, [List<Object?> args]);
  Future<void> exec(String sql, [List<Object?>? args]);
  Future<T> transaction<T>(Future<T> Function() action);
}


final backupServiceProvider = Provider<BackupService>((ref) => BackupService(ref.read(appDbProvider)));

