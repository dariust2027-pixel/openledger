import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';

/// Single shared database instance.
final appDbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});
