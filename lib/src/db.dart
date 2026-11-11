import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

/// Banco do servidor: entidades opacas com revisão por item.
final class PlannerDb {
  PlannerDb(this._db) {
    _db.execute('PRAGMA journal_mode = WAL;');
    _db.execute('PRAGMA foreign_keys = ON;');
    _migrate();
  }

  factory PlannerDb.memory() => PlannerDb(sqlite3.openInMemory());

  factory PlannerDb.open(String path) {
    Directory(File(path).parent.path).createSync(recursive: true);
    return PlannerDb(sqlite3.open(path));
  }

  final Database _db;

  void close() => _db.close();

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS devices (
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL,
        revoked_at INTEGER,
        last_seen_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS pairing_tokens (
        token_hash TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        used_at INTEGER
      );
      CREATE TABLE IF NOT EXISTS entities (
        entity TEXT NOT NULL,
        id TEXT NOT NULL,
        rev INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        origin_device TEXT NOT NULL,
        payload TEXT NOT NULL,
        PRIMARY KEY (entity, id)
      );
      CREATE TABLE IF NOT EXISTS changes (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        entity TEXT NOT NULL,
        id TEXT NOT NULL,
        rev INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS applied_changes (
        change_id TEXT PRIMARY KEY,
        entity TEXT NOT NULL,
        id TEXT NOT NULL,
        rev INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_changes_seq ON changes (seq);
    ''');
    _db.execute(
      '''
      INSERT OR IGNORE INTO meta (key, value) VALUES ('server_id', ?)
    ''',
      [_randomId()],
    );
  }

  String get serverId =>
      _db
              .select("SELECT value FROM meta WHERE key = 'server_id'")
              .first['value']
          as String;

  /// Cria um token de pareamento de uso único e devolve o valor em claro.
  ({String token, int expiresAt}) createPairingToken({
    required Duration ttl,
    DateTime? now,
  }) {
    final token = _randomToken();
    final created = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    final expires = created + ttl.inMilliseconds;
    _db.execute(
      'INSERT INTO pairing_tokens (token_hash, created_at, expires_at) '
      'VALUES (?, ?, ?)',
      [hashToken(token), created, expires],
    );
    return (token: token, expiresAt: expires);
  }

  /// Consome um token de pareamento e registra o dispositivo.
  ({String deviceId, String token})? pairDevice({
    required String pairingToken,
    required String deviceId,
    required String deviceName,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    final hash = hashToken(pairingToken);
    final rows = _db.select(
      'SELECT expires_at, used_at FROM pairing_tokens WHERE token_hash = ?',
      [hash],
    );
    if (rows.isEmpty) return null;
    final expiresAt = rows.first['expires_at'] as int;
    if (rows.first['used_at'] != null || expiresAt < timestamp) return null;

    final token = _randomToken();
    _db.execute('UPDATE pairing_tokens SET used_at = ? WHERE token_hash = ?', [
      timestamp,
      hash,
    ]);
    _db.execute(
      'INSERT INTO devices (id, label, token_hash, created_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT (id) DO UPDATE SET label = excluded.label, '
      'token_hash = excluded.token_hash, revoked_at = NULL',
      [deviceId, deviceName, hashToken(token), timestamp],
    );
    return (deviceId: deviceId, token: token);
  }

  String? deviceIdForToken(String token) {
    final rows = _db.select(
      'SELECT id FROM devices WHERE token_hash = ? AND revoked_at IS NULL',
      [hashToken(token)],
    );
    if (rows.isEmpty) return null;
    final id = rows.first['id'] as String;
    touchDevice(id);
    return id;
  }

  void touchDevice(String id, {DateTime? now}) {
    _db.execute('UPDATE devices SET last_seen_at = ? WHERE id = ?', [
      (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch,
      id,
    ]);
  }

  /// Renomeia um dispositivo pareado.
  bool renameDevice(String id, String label) {
    _db.execute('UPDATE devices SET label = ? WHERE id = ?', [label, id]);
    return _db.updatedRows > 0;
  }

  bool revokeDevice(String id, {DateTime? now}) {
    final timestamp = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    _db.execute(
      'UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL',
      [timestamp, id],
    );
    return _db.updatedRows > 0;
  }

  List<Map<String, Object?>> listDevices() => [
    for (final row in _db.select(
      'SELECT id, label, created_at, revoked_at, last_seen_at FROM devices '
      'ORDER BY created_at',
    ))
      {
        'deviceId': row['id'],
        'label': row['label'],
        'createdAt': row['created_at'],
        'revokedAt': row['revoked_at'],
        'lastSeenAt': row['last_seen_at'],
      },
  ];

  /// Aplica um lote de alterações e devolve acks e conflitos.
  ({List<Map<String, Object?>> acks, List<Map<String, Object?>> conflicts})
  applyChanges({
    required String deviceId,
    required List<Map<String, Object?>> changes,
  }) {
    final acks = <Map<String, Object?>>[];
    final conflicts = <Map<String, Object?>>[];

    _db.execute('BEGIN IMMEDIATE');
    try {
      for (final change in changes) {
        final changeId = change['changeId'] as String;
        final entity = change['entity'] as String;
        final entityId = change['entityId'] as String;
        final baseRev = change['baseRev'] as int;
        final updatedAt = change['updatedAt'] as int;
        final deleted = change['deleted'] as bool;
        final payload = change['payload'] as String;

        final applied = _db.select(
          'SELECT rev FROM applied_changes WHERE change_id = ?',
          [changeId],
        );
        if (applied.isNotEmpty) {
          acks.add({
            'changeId': changeId,
            'entity': entity,
            'entityId': entityId,
            'rev': applied.first['rev'],
          });
          continue;
        }

        final current = _db.select(
          'SELECT rev, updated_at, deleted, payload FROM entities '
          'WHERE entity = ? AND id = ?',
          [entity, entityId],
        );
        final currentRev = current.isEmpty ? 0 : current.first['rev'] as int;

        if (current.isNotEmpty && baseRev != currentRev) {
          conflicts.add({
            'entity': entity,
            'entityId': entityId,
            'server': {
              'rev': currentRev,
              'updatedAt': current.first['updated_at'],
              'deleted': (current.first['deleted'] as int) == 1,
              'payload': current.first['payload'],
            },
          });
          continue;
        }

        final nextRev = currentRev + 1;
        _db.execute(
          'INSERT INTO entities '
          '(entity, id, rev, deleted, updated_at, origin_device, payload) '
          'VALUES (?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT (entity, id) DO UPDATE SET '
          'rev = excluded.rev, deleted = excluded.deleted, '
          'updated_at = excluded.updated_at, '
          'origin_device = excluded.origin_device, payload = excluded.payload',
          [
            entity,
            entityId,
            nextRev,
            deleted ? 1 : 0,
            updatedAt,
            deviceId,
            payload,
          ],
        );
        _db.execute('INSERT INTO changes (entity, id, rev) VALUES (?, ?, ?)', [
          entity,
          entityId,
          nextRev,
        ]);
        _db.execute(
          'INSERT INTO applied_changes (change_id, entity, id, rev) '
          'VALUES (?, ?, ?, ?)',
          [changeId, entity, entityId, nextRev],
        );
        acks.add({
          'changeId': changeId,
          'entity': entity,
          'entityId': entityId,
          'rev': nextRev,
        });
      }
      _db.execute('COMMIT');
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }

    return (acks: acks, conflicts: conflicts);
  }

  /// Devolve mudanças a partir do cursor, já com o estado atual da entidade.
  ({List<Map<String, Object?>> changes, int cursor, bool more}) pullChanges({
    required int since,
    required int limit,
  }) {
    final rows = _db.select(
      'SELECT c.seq, c.entity, c.id, e.rev, e.deleted, e.updated_at, e.payload '
      'FROM changes c JOIN entities e ON e.entity = c.entity AND e.id = c.id '
      'WHERE c.seq > ? ORDER BY c.seq LIMIT ?',
      [since, limit + 1],
    );

    final more = rows.length > limit;
    final selected = rows.take(limit).toList(growable: false);
    final changes = [
      for (final row in selected)
        {
          'seq': row['seq'],
          'entity': row['entity'],
          'entityId': row['id'],
          'rev': row['rev'],
          'deleted': (row['deleted'] as int) == 1,
          'updatedAt': row['updated_at'],
          'payload': row['payload'],
        },
    ];
    final cursor = selected.isEmpty ? since : selected.last['seq'] as int;
    return (changes: changes, cursor: cursor, more: more);
  }

  /// Contagens dos dados ativos, para a confirmação antes do sync.
  Map<String, Object?> stats({required String deviceId}) {
    var postIts = 0;
    var notes = 0;
    var events = 0;
    var tasks = 0;
    var history = 0;
    var tags = 0;
    var routines = 0;
    final rows = _db.select(
      "SELECT entity, payload FROM entities WHERE deleted = 0 "
      "AND entity IN ('postIt', 'note', 'history', 'tag', 'routine')",
    );
    for (final row in rows) {
      switch (row['entity']) {
        case 'note':
          notes++;
          break;
        case 'history':
          history++;
          break;
        case 'tag':
          tags++;
          break;
        case 'routine':
          routines++;
          break;
        case 'postIt':
          postIts++;
          final payload = _decodePayload(row['payload']);
          if (payload['type'] == 'event') {
            events++;
          } else {
            tasks++;
          }
          break;
      }
    }
    return {
      'postIts': postIts,
      'notes': notes,
      'events': events,
      'tasks': tasks,
      'history': history,
      'tags': tags,
      'routines': routines,
      'deviceLabel': _deviceLabel(deviceId),
    };
  }

  String _deviceLabel(String deviceId) {
    final rows = _db.select('SELECT label FROM devices WHERE id = ?', [
      deviceId,
    ]);
    return rows.isEmpty ? '' : rows.first['label'] as String;
  }

  /// Snapshot de todas as entidades ativas, com o cursor atual.
  ({List<Map<String, Object?>> entities, int cursor}) snapshot() {
    final cursor =
        _db
                .select('SELECT COALESCE(MAX(seq), 0) AS seq FROM changes')
                .first['seq']
            as int;
    final rows = _db.select(
      'SELECT entity, id, rev, updated_at, deleted, payload FROM entities '
      'WHERE deleted = 0 ORDER BY entity, id',
    );
    return (
      entities: [
        for (final row in rows)
          {
            'entity': row['entity'],
            'entityId': row['id'],
            'rev': row['rev'],
            'updatedAt': row['updated_at'],
            'deleted': false,
            'payload': _decodePayload(row['payload']),
          },
      ],
      cursor: cursor,
    );
  }

  /// Substitui o conjunto remoto pelo snapshot enviado pelo dispositivo.
  ///
  /// Entidades remotas ausentes no snapshot viram tombstones, preservando o
  /// histórico de mudanças para os demais dispositivos. Histórico é tratado
  /// como auditoria: entradas antigas não são apagadas.
  ({List<Map<String, Object?>> entities, int cursor}) replaceDataset({
    required String deviceId,
    required List<Map<String, Object?>> entities,
  }) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final incoming = <String, Map<String, Object?>>{};
    for (final raw in entities) {
      final entity = raw['entity'] as String;
      final entityId = raw['entityId'] as String;
      incoming['$entity\u0000$entityId'] = raw;
    }

    _db.execute('BEGIN IMMEDIATE');
    try {
      final existing = _db.select(
        'SELECT entity, id, rev, deleted, payload FROM entities',
      );
      for (final row in existing) {
        final entity = row['entity'] as String;
        final entityId = row['id'] as String;
        final key = '$entity\u0000$entityId';
        if (incoming.containsKey(key) || entity == 'history') continue;
        if ((row['deleted'] as int) == 1) continue;

        final payload = _decodePayload(row['payload']);
        payload['deletedAt'] = _isoTime(now);
        payload['updatedAt'] = _isoTime(now);
        final nextRev = (row['rev'] as int) + 1;
        _writeEntity(
          entity: entity,
          entityId: entityId,
          rev: nextRev,
          deleted: true,
          updatedAt: now,
          originDevice: deviceId,
          payload: jsonEncode(payload),
        );
        _writeChange(entity, entityId, nextRev);
      }

      final result = <Map<String, Object?>>[];
      for (final entry in incoming.entries) {
        final raw = entry.value;
        final entity = raw['entity'] as String;
        final entityId = raw['entityId'] as String;
        final payload = Map<String, Object?>.from(raw['payload'] as Map);
        final deleted = payload['deletedAt'] != null;
        final existingRow = _db.select(
          'SELECT rev FROM entities WHERE entity = ? AND id = ?',
          [entity, entityId],
        );
        final nextRev = existingRow.isEmpty
            ? 1
            : (existingRow.first['rev'] as int) + 1;
        _writeEntity(
          entity: entity,
          entityId: entityId,
          rev: nextRev,
          deleted: deleted,
          updatedAt: now,
          originDevice: deviceId,
          payload: jsonEncode(payload),
        );
        _writeChange(entity, entityId, nextRev);
        result.add({'entity': entity, 'entityId': entityId, 'rev': nextRev});
      }

      final cursor =
          _db
                  .select('SELECT COALESCE(MAX(seq), 0) AS seq FROM changes')
                  .first['seq']
              as int;
      _db.execute('COMMIT');
      return (entities: result, cursor: cursor);
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _writeEntity({
    required String entity,
    required String entityId,
    required int rev,
    required bool deleted,
    required int updatedAt,
    required String originDevice,
    required String payload,
  }) {
    _db.execute(
      'INSERT INTO entities '
      '(entity, id, rev, deleted, updated_at, origin_device, payload) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT (entity, id) DO UPDATE SET '
      'rev = excluded.rev, deleted = excluded.deleted, '
      'updated_at = excluded.updated_at, origin_device = excluded.origin_device, '
      'payload = excluded.payload',
      [
        entity,
        entityId,
        rev,
        deleted ? 1 : 0,
        updatedAt,
        originDevice,
        payload,
      ],
    );
  }

  void _writeChange(String entity, String entityId, int rev) {
    _db.execute('INSERT INTO changes (entity, id, rev) VALUES (?, ?, ?)', [
      entity,
      entityId,
      rev,
    ]);
  }

  static Map<String, Object?> _decodePayload(Object? raw) {
    if (raw is String) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    }
    return <String, Object?>{};
  }

  static String _isoTime(int milliseconds) =>
      DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
        isUtc: true,
      ).toIso8601String();

  String _randomToken() => base64Url
      .encode(List<int>.generate(32, (_) => RandomSeed.nextByte()))
      .replaceAll('=', '');

  String _randomId() => _randomToken().substring(0, 16);
}

/// Bytes aleatórios sem depender de `dart:math` inseguro na API pública.
abstract final class RandomSeed {
  static final Random _random = Random.secure();

  static int nextByte() => _random.nextInt(256);
}

String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

String newToken() => base64Url
    .encode(List<int>.generate(32, (_) => RandomSeed.nextByte()))
    .replaceAll('=', '');
