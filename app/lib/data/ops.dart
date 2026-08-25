import 'dart:convert';

import '../db/database.dart';
import 'customer_repository.dart' show newId, nowMs;

/// Writes an operation into the local append-only ops_log.
/// Every repository mutation calls this — the ops_log is simultaneously the
/// audit trail and the unit of sync (Phase 4).
Future<void> logOp(
  AppDatabase db, {
  required String entity,
  required String entityId,
  required String opType,
  Map<String, Object?>? payload,
}) async {
  await db.exec(
    'INSERT INTO ops_log (id, entity, entity_id, op_type, payload_json, device_id, lamport, ts, synced) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)',
    [
      newId(),
      entity,
      entityId,
      opType,
      payload == null ? null : jsonEncode(payload),
      'local-device',
      DateTime.now().microsecondsSinceEpoch,
      nowMs(),
    ],
  );
}
