import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'db.dart';
import 'web.dart';

const serverVersion = '0.1.0';
const syncEntities = {'postIt', 'note', 'history'};
const _maxPullLimit = 500;
const _defaultPullLimit = 200;

Handler buildHandler({
  required PlannerDb db,
  required String adminToken,
  int maxBodyBytes = 8 * 1024 * 1024,
  int maxPayloadBytes = 1024 * 1024,
}) {
  final router = Router();
  final sessions = AdminSessions();

  Future<Response> web(Request request) async {
    final response = await adminWebRoute(request, db, adminToken, sessions);
    return response ?? _json(404, {'error': 'not_found'});
  }

  router.get('/', web);
  router.post('/login', web);
  router.post('/logout', web);
  router.get('/api/pairing', web);
  router.get('/api/devices', web);
  router.post(
    '/api/devices/<id>/label',
    (Request request, String id) => web(request),
  );
  router.post(
    '/api/devices/<id>/revoke',
    (Request request, String id) => web(request),
  );

  router.get('/v1/health', (Request request) {
    return _json(200, {
      'ok': true,
      'version': serverVersion,
      'serverId': db.serverId,
    });
  });

  router.post('/v1/sync', (Request request) async {
    final deviceId = _authenticatedDevice(request, db);
    if (deviceId == null) return _json(401, {'error': 'unauthorized'});

    final body = await _readJson(request, maxBodyBytes);
    if (body == null) return _json(400, {'error': 'invalid_body'});

    final since = _asInt(body['since']) ?? 0;
    final limit = (_asInt(body['limit']) ?? _defaultPullLimit).clamp(
      1,
      _maxPullLimit,
    );
    if (body['deviceId'] != deviceId) {
      return _json(403, {'error': 'device_mismatch'});
    }

    final rawChanges = body['changes'];
    if (rawChanges is! List) return _json(400, {'error': 'invalid_changes'});
    if (rawChanges.length > _maxPullLimit) {
      return _json(413, {'error': 'too_many_changes'});
    }

    final changes = <Map<String, Object?>>[];
    for (final raw in rawChanges) {
      if (raw is! Map) return _json(400, {'error': 'invalid_change'});
      final change = Map<String, Object?>.from(raw);
      final entity = change['entity'];
      final entityId = change['entityId'];
      final changeId = change['changeId'];
      final baseRev = _asInt(change['baseRev']);
      final updatedAt = _asInt(change['updatedAt']);
      final deleted = change['deleted'];
      final payload = change['payload'];

      if (entity is! String || !syncEntities.contains(entity)) {
        return _json(400, {'error': 'invalid_entity'});
      }
      if (entityId is! String || entityId.isEmpty || entityId.length > 200) {
        return _json(400, {'error': 'invalid_entity_id'});
      }
      if (changeId is! String || changeId.isEmpty) {
        return _json(400, {'error': 'invalid_change_id'});
      }
      if (baseRev == null || baseRev < 0) {
        return _json(400, {'error': 'invalid_base_rev'});
      }
      if (updatedAt == null || updatedAt < 0) {
        return _json(400, {'error': 'invalid_updated_at'});
      }
      if (deleted is! bool) {
        return _json(400, {'error': 'invalid_deleted'});
      }
      if (payload is! String || payload.length > maxPayloadBytes) {
        return _json(413, {'error': 'invalid_payload'});
      }

      changes.add({
        'changeId': changeId,
        'entity': entity,
        'entityId': entityId,
        'baseRev': baseRev,
        'updatedAt': updatedAt,
        'deleted': deleted,
        'payload': payload,
      });
    }

    final applied = db.applyChanges(deviceId: deviceId, changes: changes);
    final pulled = db.pullChanges(since: since, limit: limit);

    return _json(200, {
      'acks': applied.acks,
      'conflicts': applied.conflicts,
      'changes': pulled.changes,
      'cursor': pulled.cursor,
      'more': pulled.more,
    });
  });

  router.get('/v1/sync/stats', (Request request) {
    final deviceId = _authenticatedDevice(request, db);
    if (deviceId == null) return _json(401, {'error': 'unauthorized'});
    return _json(200, db.stats(deviceId: deviceId));
  });

  router.get('/v1/sync/snapshot', (Request request) {
    final deviceId = _authenticatedDevice(request, db);
    if (deviceId == null) return _json(401, {'error': 'unauthorized'});
    final snapshot = db.snapshot();
    return _json(200, {
      'entities': snapshot.entities,
      'cursor': snapshot.cursor,
    });
  });

  router.post('/v1/sync/replace', (Request request) async {
    final deviceId = _authenticatedDevice(request, db);
    if (deviceId == null) return _json(401, {'error': 'unauthorized'});

    final body = await _readJson(request, maxBodyBytes);
    if (body == null) return _json(400, {'error': 'invalid_body'});
    if (body['deviceId'] != deviceId) {
      return _json(403, {'error': 'device_mismatch'});
    }
    final rawEntities = body['entities'];
    if (rawEntities is! List) return _json(400, {'error': 'invalid_entities'});
    if (rawEntities.length > 20000) {
      return _json(413, {'error': 'too_many_entities'});
    }

    final entities = <Map<String, Object?>>[];
    for (final raw in rawEntities) {
      if (raw is! Map) return _json(400, {'error': 'invalid_entity'});
      final map = Map<String, Object?>.from(raw);
      final entity = map['entity'];
      final entityId = map['entityId'];
      final payload = map['payload'];
      if (entity is! String || !syncEntities.contains(entity)) {
        return _json(400, {'error': 'invalid_entity'});
      }
      if (entityId is! String || entityId.isEmpty || entityId.length > 200) {
        return _json(400, {'error': 'invalid_entity_id'});
      }
      if (payload is! Map) return _json(400, {'error': 'invalid_payload'});
      if (jsonEncode(payload).length > maxPayloadBytes) {
        return _json(413, {'error': 'invalid_payload'});
      }
      entities.add({
        'entity': entity,
        'entityId': entityId,
        'payload': Map<String, Object?>.from(payload),
      });
    }

    final result = db.replaceDataset(deviceId: deviceId, entities: entities);
    return _json(200, {'entities': result.entities, 'cursor': result.cursor});
  });

  router.post('/v1/pair', (Request request) async {
    final body = await _readJson(request, maxBodyBytes);
    if (body == null) return _json(400, {'error': 'invalid_body'});
    final pairingToken = body['pairingToken'];
    final deviceId = body['deviceId'];
    final deviceName = body['deviceName'];
    if (pairingToken is! String ||
        deviceId is! String ||
        deviceId.isEmpty ||
        deviceName is! String ||
        deviceName.isEmpty) {
      return _json(400, {'error': 'invalid_pairing'});
    }

    final result = db.pairDevice(
      pairingToken: pairingToken,
      deviceId: deviceId,
      deviceName: deviceName,
    );
    if (result == null) return _json(401, {'error': 'invalid_pairing'});
    return _json(200, {'deviceId': result.deviceId, 'token': result.token});
  });

  router.post('/v1/admin/pairing-tokens', (Request request) async {
    if (!_isAdmin(request, adminToken)) {
      return _json(401, {'error': 'unauthorized'});
    }
    final body = await _readJson(request, maxBodyBytes) ?? const {};
    final ttlSeconds = (_asInt(body['ttlSeconds']) ?? 300).clamp(30, 3600);
    final created = db.createPairingToken(ttl: Duration(seconds: ttlSeconds));
    return _json(200, {
      'pairingToken': created.token,
      'expiresAt': created.expiresAt,
      'serverId': db.serverId,
    });
  });

  router.get('/v1/admin/devices', (Request request) {
    if (!_isAdmin(request, adminToken)) {
      return _json(401, {'error': 'unauthorized'});
    }
    return _json(200, {'devices': db.listDevices()});
  });

  router.post('/v1/admin/devices/<id>/revoke', (Request request, String id) {
    if (!_isAdmin(request, adminToken)) {
      return _json(401, {'error': 'unauthorized'});
    }
    final revoked = db.revokeDevice(id);
    if (!revoked) return _json(404, {'error': 'not_found'});
    return _json(200, {'revoked': true});
  });

  return const Pipeline().addHandler(router.call);
}

String? _authenticatedDevice(Request request, PlannerDb db) {
  final token = _bearer(request);
  if (token == null) return null;
  return db.deviceIdForToken(token);
}

bool _isAdmin(Request request, String adminToken) {
  final token = _bearer(request);
  if (token == null || token.isEmpty || adminToken.isEmpty) return false;
  return _constantTimeEquals(hashToken(token), hashToken(adminToken));
}

String? _bearer(Request request) {
  final header = request.headers['authorization'];
  if (header == null || !header.toLowerCase().startsWith('bearer ')) {
    return null;
  }
  return header.substring(7).trim();
}

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var index = 0; index < a.length; index++) {
    diff |= a.codeUnitAt(index) ^ b.codeUnitAt(index);
  }
  return diff == 0;
}

Future<Map<String, Object?>?> _readJson(Request request, int maxBytes) async {
  final text = await request.readAsString();
  if (text.isEmpty || text.length > maxBytes) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    return Map<String, Object?>.from(decoded);
  } on FormatException {
    return null;
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

Response _json(int status, Map<String, Object?> body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json; charset=utf-8'},
);
