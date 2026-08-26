import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../db/database.dart';
import '../db/providers.dart';
import 'customer_repository.dart' show newId, nowMs;
import 'ops.dart';

class ItemRepository {
  final AppDatabase db;
  ItemRepository(this.db);

  Future<List<Map<String, dynamic>>> all() =>
      db.rows('SELECT * FROM items ORDER BY name COLLATE NOCASE');

  Stream<List<Map<String, dynamic>>> watchAll() =>
      db.watchRows('SELECT * FROM items ORDER BY name COLLATE NOCASE');

  Future<Map<String, dynamic>?> byId(String id) async {
    final rs = await db.rows('SELECT * FROM items WHERE id = ?', [id]);
    return rs.isEmpty ? null : rs.first;
  }

  Future<String> create({
    required String name,
    String? sku,
    required int unitPriceMinor,
    required double qtyOnHand,
    int costMinor = 0,
  }) async {
    final id = newId();
    final now = nowMs();
    await db.exec(
      'INSERT INTO items (id, name, sku, unit_price, qty_on_hand, cost_minor, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [id, name, sku, unitPriceMinor, qtyOnHand, costMinor, now, now],
    );
    await logOp(db, entity: 'items', entityId: id, opType: 'create', payload: {
      'id': id, 'name': name, 'sku': sku, 'unit_price': unitPriceMinor,
      'qty_on_hand': qtyOnHand, 'cost_minor': costMinor,
      'created_at': now, 'updated_at': now,
    });
    return id;
  }

  Future<void> update(String id,
      {String? name, String? sku, int? unitPriceMinor, double? qtyOnHand, int? costMinor}) async {
    await db.exec(
      '''UPDATE items SET
         name = COALESCE(?, name), sku = COALESCE(?, sku),
         unit_price = COALESCE(?, unit_price), qty_on_hand = COALESCE(?, qty_on_hand),
         cost_minor = COALESCE(?, cost_minor), updated_at = ?
         WHERE id = ?''',
      [name, sku, unitPriceMinor, qtyOnHand, costMinor, nowMs(), id],
    );
    final row = await byId(id);
    if (row != null) {
      await logOp(db, entity: 'items', entityId: id, opType: 'update', payload: row);
    }
  }

  /// Positive delta = stock in (purchase/received), negative = stock out (sale).
  Future<void> adjustStock(String itemId, double delta) async {
    await db.exec('UPDATE items SET qty_on_hand = qty_on_hand + ?, updated_at = ? WHERE id = ?',
        [delta, nowMs(), itemId]);
    final row = await byId(itemId);
    if (row != null) {
      await logOp(db, entity: 'items', entityId: itemId, opType: 'update',
          payload: {'qty_on_hand': row['qty_on_hand'], 'updated_at': row['updated_at']});
    }
  }

  Future<void> delete(String id) async {
    await db.exec('DELETE FROM items WHERE id = ?', [id]);
    await logOp(db, entity: 'items', entityId: id, opType: 'delete');
  }

  Future<List<Map<String, dynamic>>> lowStock({double threshold = 5}) => db
      .rows('SELECT * FROM items WHERE qty_on_hand <= ? ORDER BY qty_on_hand', [threshold]);
}

final itemRepoProvider =
    Provider<ItemRepository>((ref) => ItemRepository(ref.read(appDbProvider)));
