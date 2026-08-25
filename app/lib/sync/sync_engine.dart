import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../db/database.dart';
import '../db/providers.dart';

/// Client half of the Phase-4 sync protocol.
///
/// Push:  local ops_log rows with synced=0 → POST /v1/ops/push → synced=1.
/// Pull:  GET /v1/ops/pull?cursor=N → apply ops idempotently (skip op IDs
///        already present; LWW per entity row on updated_at) → save cursor.
enum SyncStatus { disabled, idle, syncing, error }

class SyncState {
  final SyncStatus status;
  final String message;
  final DateTime? lastSync;
  final int pendingOps;

  const SyncState({
    this.status = SyncStatus.disabled,
    this.message = '',
    this.lastSync,
    this.pendingOps = 0,
  });

  SyncState copyWith({
    SyncStatus? status, String? message, DateTime? lastSync, int? pendingOps,
  }) => SyncState(
        status: status ?? this.status,
        message: message ?? this.message,
        lastSync: lastSync ?? this.lastSync,
        pendingOps: pendingOps ?? this.pendingOps,
      );
}

class SyncEngine extends Notifier<SyncState> {
  static const _kServerUrl = 'sync_server_url';
  static const _kDeviceToken = 'sync_device_token';
  static const _kPullCursor = 'sync_pull_cursor';
  static const _kLastSync = 'sync_last_sync_ms';

  final _secure = const FlutterSecureStorage();
  http.Client? _client;
  Timer? _timer;

  String _serverUrl = '';
  String _deviceToken = '';

  @override
  SyncState build() {
    _init();
    return const SyncState(status: SyncStatus.idle, message: 'Starting…');
  }

  Future<void> _init() async {
    _serverUrl = await _secure.read(key: _kServerUrl) ?? '';
    _deviceToken = await _secure.read(key: _kDeviceToken) ?? '';

    final lastMs = await ref.read(appDbProvider).getSetting<int>(_kLastSync, 0);
    final configured = isConfigured;
    state = state.copyWith(
      status: configured ? SyncStatus.idle : SyncStatus.disabled,
      message: configured ? '' : 'Not paired with a server',
      lastSync: lastMs > 0 ? DateTime.fromMillisecondsSinceEpoch(lastMs) : null,
    );
    await refreshPendingCount();

    // Background sync loop — cheap no-op when unpaired or offline.
    _timer?.cancel();
    if (configured) {
      _timer = Timer.periodic(const Duration(seconds: 60), (_) => syncNow());
    }
    ref.onDispose(() => _timer?.cancel());
  }

  bool get isConfigured => _serverUrl.isNotEmpty && _deviceToken.isNotEmpty;

  /* --------------------------- configuration --------------------------- */

  /// Pairs this device with a server by calling its register endpoint and
  /// storing the returned token in secure storage.
  Future<String?> pair(String serverUrl) async {
    final url = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final res = await (_client ??= http.Client())
          .post(Uri.parse('$url/v1/devices/register'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'name': 'flutter-${DateTime.now().millisecondsSinceEpoch}'}))
          .timeout(const Duration(seconds: 10));

      if (res.statusCode != 201) {
        return 'Server returned ${res.statusCode}';
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      await _secure.write(key: _kServerUrl, value: url);
      await _secure.write(key: _kDeviceToken, value: data['token'] as String);
      _serverUrl = url;
      _deviceToken = data['token'] as String;
      state = state.copyWith(status: SyncStatus.idle, message: 'Paired with $url');
      _startTimer();
      return null; // success
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> unpair() async {
    await _secure.delete(key: _kServerUrl);
    await _secure.delete(key: _kDeviceToken);
    await ref.read(appDbProvider).setSetting(_kPullCursor, '0');
    _timer?.cancel();
    _serverUrl = '';
    _deviceToken = '';
    state = const SyncState(status: SyncStatus.disabled, message: 'Unpaired');
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => syncNow());
  }

  /* ------------------------------ syncing ------------------------------ */

  Future<void> refreshPendingCount() async {
    final rs = await ref
        .read(appDbProvider)
        .rows('SELECT COUNT(*) AS c FROM ops_log WHERE synced = 0');
    state = state.copyWith(pendingOps: rs.first['c'] as int);
  }

  Future<bool> syncNow() async {
    if (!isConfigured || state.status == SyncStatus.syncing) return false;
    state = state.copyWith(status: SyncStatus.syncing, message: 'Syncing…');
    try {
      await _pushPending();
      await _pullRemote();
      await refreshPendingCount();
      final now = DateTime.now();
      await ref.read(appDbProvider).setSetting(_kLastSync, '${now.millisecondsSinceEpoch}');
      state = state.copyWith(
          status: SyncStatus.idle, message: 'Synced', lastSync: now);
      return true;
    } catch (e) {
      state = state.copyWith(status: SyncStatus.error, message: '$e');
      return false;
    }
  }

  Future<void> _pushPending() async {
    final db = ref.read(appDbProvider);
    final ops = await db.rows(
        'SELECT id, entity, entity_id, op_type, payload_json, lamport, ts '
        'FROM ops_log WHERE synced = 0 ORDER BY ts LIMIT 200');
    if (ops.isEmpty) return;

    final body = jsonEncode({
      'ops': [
        for (final o in ops)
          {
            'id': o['id'],
            'entity': o['entity'],
            'entity_id': o['entity_id'],
            'op_type': o['op_type'],
            'payload': o['payload_json'] == null
                ? null
                : jsonDecode(o['payload_json'] as String),
            'lamport': o['lamport'],
            'ts': o['ts'],
          },
      ],
    });

    final res = await (_client ??= http.Client()).post(
      Uri.parse('$_serverUrl/v1/ops/push'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_deviceToken',
      },
      body: body,
    ).timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) {
      throw Exception('push failed ${res.statusCode}');
    }

    // Mark all submitted ops synced (idempotent server accepted them).
    final ids = ops.map((o) => o['id']).toList();
    await db.exec(
        'UPDATE ops_log SET synced = 1 WHERE id IN (${ids.map((_) => '?').join(',')})',
        ids);
  }

  Future<void> _pullRemote() async {
    final db = ref.read(appDbProvider);
    var cursor =
        int.tryParse(await db.getSetting<String>(_kPullCursor, '0')) ?? 0;

    while (true) {
      final res = await (_client ??= http.Client()).get(
        Uri.parse('$_serverUrl/v1/ops/pull?cursor=$cursor&limit=500'),
        headers: {'Authorization': 'Bearer $_deviceToken'},
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        throw Exception('pull failed ${res.statusCode}');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final ops = (data['ops'] as List?) ?? [];
      if (ops.isEmpty) return;

      for (final op in ops) {
        await _applyOp((op as Map).cast<String, dynamic>());
      }
      final newCursor = (data['new_cursor'] as num).toInt();
      if (newCursor <= cursor) return; // safety against loops
      cursor = newCursor;
      await db.setSetting(_kPullCursor, '$cursor');
      if ((data['count'] as num).toInt() < 500) return;
    }
  }

  /// Idempotent application: skip ops we already have; upsert entity rows
  /// with last-write-wins on updated_at.
  Future<void> _applyOp(Map<String, dynamic> op) async {
    final db = ref.read(appDbProvider);

    // Already applied locally?
    final known = await db.rows('SELECT 1 FROM ops_log WHERE id = ?', [op['id']]);
    if (known.isNotEmpty) return;

    final payload = op['payload'];
    final payloadMap =
        payload is Map ? payload.cast<String, dynamic>() : <String, dynamic>{};

    const deletableEntities = {'customers': 'customers', 'expenses': 'expenses'};
    if (op['op_type'] == 'delete') {
      final table = deletableEntities[op['entity']];
      if (table != null) {
        await db.exec('DELETE FROM $table WHERE id = ?', [op['entity_id']]);
      }
      await _recordApplied(db, op);
      return;
    }

    switch (op['entity'] as String) {
      case 'customers':
        await _upsert(db, 'customers', [
          'id,name,email,phone,currency,notes,created_at,updated_at',
        ], payloadMap, conflictCols: ['name', 'email', 'phone', 'currency', 'notes']);
        break;
      case 'expenses':
        await _upsert(db, 'expenses', [
          'id,date,vendor,category_id,description,amount,tax_amount,currency,'
              'payment_method,receipt_path,billable,created_at,updated_at',
        ], payloadMap, conflictCols: [
          'date', 'vendor', 'category_id', 'description', 'amount',
          'tax_amount', 'currency', 'payment_method', 'receipt_path', 'billable'
        ]);
        break;
      case 'payments':
        await db.exec(
          'INSERT INTO payments (id, invoice_id, expense_id, date, amount, method, reference, created_at, updated_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO NOTHING',
          [
            payloadMap['id'], payloadMap['invoice_id'], payloadMap['expense_id'],
            payloadMap['date'], payloadMap['amount'], payloadMap['method'],
            payloadMap['reference'], payloadMap['created_at'], payloadMap['updated_at'],
          ],
        );
        break;
      case 'invoices':
        // Upsert invoice header + replace lines only if newer.
        final updated = payloadMap['updated_at'];
        if (updated is int && await _isNewer(db, 'invoices', op['entity_id'] as String, updated)) {
          await db.transaction(() async {
            await db.exec('DELETE FROM invoice_lines WHERE invoice_id = ?', [op['entity_id']]);
            await db.exec(
              'INSERT INTO invoices (id, number, customer_id, status, issue_date, due_date, currency, '
              'subtotal, tax_total, total, notes, created_at, updated_at) '
              'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
              'ON CONFLICT(id) DO UPDATE SET status=excluded.status, due_date=excluded.due_date, '
              'subtotal=excluded.subtotal, tax_total=excluded.tax_total, total=excluded.total, '
              'notes=excluded.notes, updated_at=excluded.updated_at',
              [
                payloadMap['id'], payloadMap['number'], payloadMap['customer_id'],
                payloadMap['status'], payloadMap['issue_date'], payloadMap['due_date'],
                payloadMap['currency'], payloadMap['subtotal'], payloadMap['tax_total'],
                payloadMap['total'], payloadMap['notes'], payloadMap['created_at'], updated,
              ],
            );
            for (final l in (payloadMap['lines'] as List? ?? [])) {
              final m = (l as Map).cast<String, dynamic>();
              await db.exec(
                'INSERT INTO invoice_lines (id, invoice_id, description, qty, unit_price, tax_percent, line_total, position) '
                'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                [m['id'], m['invoice_id'], m['description'], m['qty'],
                 m['unit_price'], m['tax_percent'], m['line_total'], m['position']],
              );
            }
          });
        }
        break;
      default:
        break; // unknown entity types are logged but not applied
    }

    // Record the applied op so it's never re-applied.
    await _recordApplied(db, op);
  }

  Future<void> _recordApplied(AppDatabase db, Map<String, dynamic> op) async {
    await db.exec(
      'INSERT OR IGNORE INTO ops_log (id, entity, entity_id, op_type, payload_json, device_id, lamport, ts, synced) '
      'VALUES (?, ?, ?, ?, NULL, ?, ?, ?, 2)',
      [
        op['id'], op['entity'], op['entity_id'], op['op_type'],
        op['device_id'] ?? 'remote', op['lamport'] ?? 0, op['ts'] ?? 0,
      ],
    );
  }

  Future<bool> _isNewer(AppDatabase db, String table, String id, int remoteUpdated) async {
    final rs = await db.rows('SELECT updated_at FROM $table WHERE id = ?', [id]);
    if (rs.isEmpty) return true;
    return remoteUpdated > (rs.first['updated_at'] as int? ?? 0);
  }

  /// Generic LWW upsert used for simple flat entities.
  Future<void> _upsert(AppDatabase db, String table, List<String> colsAndArgs,
      Map<String, dynamic> p, {required List<String> conflictCols}) async {
    final cols = colsAndArgs.first.split(',');
    if (!cols.every(p.containsKey)) {
      // Payload incomplete for direct upsert — skip rather than corrupt.
      return;
    }
    final setClause = conflictCols.map((c) => '$c=excluded.$c').join(', ');
    await db.exec(
      'INSERT INTO $table (${cols.join(',')}) VALUES (${cols.map((_) => '?').join(',')}) '
      'ON CONFLICT(id) DO UPDATE SET $setClause, updated_at=excluded.updated_at '
      'WHERE excluded.updated_at > $table.updated_at',
      [for (final c in cols) p[c]],
    );
  }
}

final syncEngineProvider =
    NotifierProvider<SyncEngine, SyncState>(SyncEngine.new);
