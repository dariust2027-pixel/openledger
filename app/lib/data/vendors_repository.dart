import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/providers.dart';
import 'customer_repository.dart' show newId, nowMs;
import 'ops.dart';

class VendorRepository {
  final AppDatabase db;
  VendorRepository(this.db);

  Future<List<Map<String, dynamic>>> all() =>
      db.rows('SELECT * FROM vendors ORDER BY name COLLATE NOCASE');

  Stream<List<Map<String, dynamic>>> watchAll() =>
      db.watchRows('SELECT * FROM vendors ORDER BY name COLLATE NOCASE');

  Future<Map<String, dynamic>?> byId(String id) async {
    final rs = await db.rows('SELECT * FROM vendors WHERE id = ?', [id]);
    return rs.isEmpty ? null : rs.first;
  }

  Future<Map<String, dynamic>?> findByName(String name) async {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return null;
    for (final (sql, args) in [
      ('SELECT * FROM vendors WHERE lower(name) = ? LIMIT 2', [n]),
      ('SELECT * FROM vendors WHERE lower(name) LIKE ? LIMIT 2', ['$n%']),
      ('SELECT * FROM vendors WHERE lower(name) LIKE ? LIMIT 3', ['%$n%']),
    ]) {
      final rs = await db.rows(sql, args);
      if (rs.length == 1) return rs.first;
      if (rs.length > 1) return rs.first; // vendors: pick first on ambiguity
    }
    return null;
  }

  Future<String> create({
    required String name,
    String? email,
    String? phone,
    String? notes,
  }) async {
    final id = newId();
    final now = nowMs();
    await db.exec(
      'INSERT INTO vendors (id, name, email, phone, notes, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [id, name, email, phone, notes, now, now],
    );
    await logOp(db, entity: 'vendors', entityId: id, opType: 'create', payload: {
      'id': id, 'name': name, 'email': email, 'phone': phone,
      'notes': notes, 'created_at': now, 'updated_at': now,
    });
    return id;
  }

  Future<void> delete(String id) async {
    await db.exec('DELETE FROM vendors WHERE id = ?', [id]);
    await logOp(db, entity: 'vendors', entityId: id, opType: 'delete');
  }
}

final vendorRepoProvider =
    Provider<VendorRepository>((ref) => VendorRepository(ref.read(appDbProvider)));
