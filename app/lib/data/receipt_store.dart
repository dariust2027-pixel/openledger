import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'customer_repository.dart' show newId;

/// Stores receipt images/PDFs under the app documents dir with a
/// sync-friendly layout: `receipts/<uuid>.<ext>`.
///
/// The file name doubles as the server blob id, so the SyncEngine can
/// upload/download attachments without extra metadata.
class ReceiptStore {
  /// Copies [sourcePath] into the receipts folder. Returns the relative
  /// path to store in the DB (portable across devices).
  static Future<String> save(String sourcePath) async {
    final dir = await _receiptsDir();
    final ext = sourcePath.contains('.')
        ? sourcePath.substring(sourcePath.lastIndexOf('.'))
        : '.jpg';
    final name = '${newId()}$ext';
    await File(sourcePath).copy('${dir.path}/$name');
    return 'receipts/$name';
  }

  /// Resolves a stored path (relative or legacy absolute) for display.
  static Future<String?> resolve(String? stored) async {
    if (stored == null || stored.isEmpty) return null;
    if (!stored.startsWith('receipts/')) {
      return File(stored).existsSync() ? stored : null; // legacy absolute path
    }
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/$stored');
    return f.existsSync() ? f.path : null;
  }

  static Future<Directory> _receiptsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/receipts');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
}
