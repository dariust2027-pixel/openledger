import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../db/database.dart';
import '../db/providers.dart';
import 'ops.dart';

final _uuid = const Uuid();

class AmbiguousMatchException implements Exception {
  final List<String> candidates;
  AmbiguousMatchException(this.candidates);
}

String newId() => _uuid.v4();
int nowMs() => DateTime.now().millisecondsSinceEpoch;

class CustomerRepository {
  final AppDatabase db;
  CustomerRepository(this.db);

  Future<List<Map<String, dynamic>>> all() =>
      db.rows('SELECT * FROM customers ORDER BY name COLLATE NOCASE');

  Stream<List<Map<String, dynamic>>> watchAll() =>
      db.watchRows('SELECT * FROM customers ORDER BY name COLLATE NOCASE');

  Future<Map<String, dynamic>?> byId(String id) async {
    final rs = await db.rows('SELECT * FROM customers WHERE id = ?', [id]);
    return rs.isEmpty ? null : rs.first;
  }

  /// Lookup used by the AI layer: exact → prefix → contains.
  /// Zero matches → null. One → the row. Many on exact/prefix → ambiguous.
  Future<Map<String, dynamic>?> findByName(String name) async {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return null;
    for (final (sql, args) in [
      ('SELECT * FROM customers WHERE lower(name) = ? LIMIT 2', [n]),
      ('SELECT * FROM customers WHERE lower(name) LIKE ? LIMIT 2', ['$n%']),
      ('SELECT * FROM customers WHERE lower(name) LIKE ? LIMIT 3', ['%$n%']),
    ]) {
      final rs = await db.rows(sql, args);
      if (rs.length == 1) return rs.first;
      if (rs.length > 1) {
        throw AmbiguousMatchException(rs.map((r) => r['name'] as String).toList());
      }
    }
    return null;
  }

  Future<String> create({
    required String name,
    String? email,
    String? phone,
    String currency = 'USD',
    String? notes,
  }) async {
    final id = newId();
    final now = nowMs();
    await db.exec(
      'INSERT INTO customers (id, name, email, phone, currency, notes, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [id, name, email, phone, currency, notes, now, now],
    );
    await logOp(db, entity: 'customers', entityId: id, opType: 'create', payload: {
      'id': id, 'name': name, 'email': email, 'phone': phone,
      'currency': currency, 'notes': notes, 'created_at': now, 'updated_at': now,
    });
    return id;
  }

  Future<void> update(String id,
      {String? name, String? email, String? phone, String? notes}) async {
    await db.exec(
      '''UPDATE customers SET
         name = COALESCE(?, name), email = COALESCE(?, email),
         phone = COALESCE(?, phone), notes = COALESCE(?, notes),
         updated_at = ? WHERE id = ?''',
      [name, email, phone, notes, nowMs(), id],
    );
    final row = await byId(id);
    if (row != null) {
      await logOp(db, entity: 'customers', entityId: id, opType: 'update', payload: row);
    }
  }

  Future<void> delete(String id) async {
    await db.exec('DELETE FROM customers WHERE id = ?', [id]);
    await logOp(db, entity: 'customers', entityId: id, opType: 'delete');
  }
}

final customerRepoProvider =
    Provider<CustomerRepository>((ref) => CustomerRepository(ref.read(appDbProvider)));
