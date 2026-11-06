import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:stick2server/src/api.dart';
import 'package:stick2server/src/db.dart';

Future<void> main(List<String> args) async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8090;
  final dbPath =
      Platform.environment['DB_PATH'] ?? 'data/planner-server.sqlite';
  final adminToken = Platform.environment['ADMIN_TOKEN'] ?? '';
  final publicUrl = Platform.environment['PUBLIC_URL'] ?? '';

  if (args.isNotEmpty && args.first == 'token') {
    stdout.writeln(newToken());
    return;
  }

  final db = PlannerDb.open(dbPath);

  switch (args.isEmpty ? 'serve' : args.first) {
    case 'pair':
      if (adminToken.isEmpty) {
        stderr.writeln('ADMIN_TOKEN ausente.');
        exitCode = 2;
        return;
      }
      final ttl = Duration(
        seconds: int.tryParse(args.length > 1 ? args[1] : '') ?? 300,
      );
      final created = db.createPairingToken(ttl: ttl);
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert({
          'url': publicUrl.isEmpty ? 'http://<host>:$port' : publicUrl,
          'serverId': db.serverId,
          'pairingToken': created.token,
          'expiresAt': DateTime.fromMillisecondsSinceEpoch(
            created.expiresAt,
            isUtc: true,
          ).toIso8601String(),
        }),
      );
      db.close();
      return;

    case 'devices':
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(db.listDevices()),
      );
      db.close();
      return;

    case 'revoke':
      if (args.length < 2) {
        stderr.writeln('Uso: server revoke <deviceId>');
        exitCode = 2;
        return;
      }
      final revoked = db.revokeDevice(args[1]);
      stdout.writeln(revoked ? 'revoked' : 'not found');
      db.close();
      return;

    case 'serve':
      if (adminToken.isEmpty) {
        stderr.writeln('ADMIN_TOKEN obrigatório para servir.');
        exitCode = 2;
        return;
      }
      final handler = buildHandler(db: db, adminToken: adminToken);
      final server = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        port,
      );
      stdout.writeln(
        'Stick2Planner sync server $serverVersion em '
        'http://${server.address.address}:${server.port}',
      );
      await ProcessSignal.sigint.watch().first;
      await server.close(force: true);
      db.close();
      return;

    default:
      stderr.writeln(
        'Comandos: serve | token | pair [ttl] | devices | revoke <id>',
      );
      exitCode = 2;
  }
}
