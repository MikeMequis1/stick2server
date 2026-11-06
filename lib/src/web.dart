import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:qr/qr.dart';
import 'package:shelf/shelf.dart';

import 'db.dart';

/// Sessões em memória para a página administrativa de pareamento.
final class AdminSessions {
  AdminSessions({this.ttl = const Duration(hours: 12)});

  final Duration ttl;
  final Map<String, DateTime> _sessions = {};
  final Random _random = Random.secure();

  String create() {
    final token = base64Url
        .encode(List<int>.generate(24, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    _sessions[token] = DateTime.now().toUtc().add(ttl);
    return token;
  }

  bool valid(String? token) {
    if (token == null) return false;
    final expiry = _sessions[token];
    if (expiry == null) return false;
    if (expiry.isBefore(DateTime.now().toUtc())) {
      _sessions.remove(token);
      return false;
    }
    return true;
  }

  void remove(String? token) {
    if (token != null) _sessions.remove(token);
  }
}

const _sessionCookie = 'planner_admin';

/// Página de login/dashboard e APIs usadas por ela.
Future<Response?> adminWebRoute(
  Request request,
  PlannerDb db,
  String adminToken,
  AdminSessions sessions,
) async {
  final path = request.url.path;
  final session = _cookie(request, _sessionCookie);

  if (path == '' && request.method == 'GET') {
    return sessions.valid(session) ? _dashboard(db) : _loginPage();
  }
  if (path == 'login' && request.method == 'POST') {
    return _login(request, adminToken, sessions);
  }
  if (path == 'logout' && request.method == 'POST') {
    sessions.remove(session);
    return _redirect('/');
  }
  if (path == 'api/pairing' && request.method == 'GET') {
    if (!sessions.valid(session)) return _json(401, {'error': 'unauthorized'});
    final base = _baseUrl(request);
    final created = db.createPairingToken(ttl: const Duration(seconds: 300));
    final payload = jsonEncode({
      'v': 1,
      'u': base,
      's': db.serverId,
      'p': created.token,
    });
    return _json(200, {
      'url': base,
      'serverId': db.serverId,
      'pairingToken': created.token,
      'expiresAt': created.expiresAt,
      'ttlMs': 300 * 1000,
      'svg': qrSvg(payload),
    });
  }
  if (path == 'api/devices' && request.method == 'GET') {
    if (!sessions.valid(session)) return _json(401, {'error': 'unauthorized'});
    return _json(200, {'devices': db.listDevices()});
  }
  if (path.startsWith('api/devices/') &&
      path.endsWith('/label') &&
      request.method == 'POST') {
    if (!sessions.valid(session)) return _json(401, {'error': 'unauthorized'});
    final segments = path.split('/');
    if (segments.length < 4) return _json(400, {'error': 'invalid_device'});
    final id = segments[2];
    final body = await _readJson(request);
    final label = (body?['label'] as String?)?.trim() ?? '';
    if (label.isEmpty || label.length > 64) {
      return _json(400, {'error': 'invalid_label'});
    }
    if (!db.renameDevice(id, label)) {
      return _json(404, {'error': 'not_found'});
    }
    return _json(200, {'label': label});
  }
  if (path.startsWith('api/devices/') &&
      path.endsWith('/revoke') &&
      request.method == 'POST') {
    if (!sessions.valid(session)) return _json(401, {'error': 'unauthorized'});
    final segments = path.split('/');
    if (segments.length < 4) return _json(400, {'error': 'invalid_device'});
    final id = segments[2];
    final revoked = db.revokeDevice(id);
    if (!revoked) return _json(404, {'error': 'not_found'});
    return _json(200, {'revoked': true});
  }

  return null;
}

Future<Response> _login(
  Request request,
  String adminToken,
  AdminSessions sessions,
) async {
  final body = await request.readAsString();
  final form = Uri.splitQueryString(body);
  final token = (form['token'] ?? '').trim();
  if (token.isEmpty || hashToken(token) != hashToken(adminToken)) {
    return Response(
      401,
      body: _loginHtml(invalid: true),
      headers: _htmlHeaders,
    );
  }
  final session = sessions.create();
  return Response(
    303,
    headers: {
      'location': '/',
      'set-cookie':
          '$_sessionCookie=$session; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200',
    },
  );
}

Response _dashboard(PlannerDb db) => Response(
  200,
  body: _dashboardHtml(serverId: db.serverId),
  headers: _htmlHeaders,
);

Response _loginPage({bool invalid = false}) => Response(
  200,
  body: _loginHtml(invalid: invalid),
  headers: _htmlHeaders,
);

const _htmlHeaders = {
  'content-type': 'text/html; charset=utf-8',
  'cache-control': 'no-store',
  'x-frame-options': 'DENY',
  'referrer-policy': 'no-referrer',
};

Response _json(int status, Map<String, Object?> body) => Response(
  status,
  body: jsonEncode(body),
  headers: {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  },
);

Response _redirect(String location) =>
    Response(303, headers: {'location': location});

String? _cookie(Request request, String name) {
  final raw = request.headers['cookie'];
  if (raw == null) return null;
  for (final part in raw.split(';')) {
    final trimmed = part.trim();
    if (trimmed.startsWith('$name=')) {
      return trimmed.substring(name.length + 1);
    }
  }
  return null;
}

String _baseUrl(Request request) {
  final forwarded = request.headers['x-forwarded-proto']
      ?.split(',')
      .first
      .trim();
  final proto = (forwarded == null || forwarded.isEmpty)
      ? request.requestedUri.scheme
      : forwarded;
  final host =
      request.headers['x-forwarded-host']?.split(',').first.trim() ??
      request.headers['host'] ??
      request.requestedUri.authority;
  return '$proto://$host';
}

Future<Map<String, Object?>?> _readJson(Request request) async {
  final text = await request.readAsString();
  if (text.isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, Object?>.from(decoded);
  } on FormatException {
    return null;
  }
  return null;
}

/// Gera um QR Code em SVG (texto puro, sem dependências nativas).
String qrSvg(String data, {int moduleSize = 6, int quiet = 4}) {
  final code = QrCode(
    payload: QrPayload.fromString(data),
    errorCorrectLevel: QrErrorCorrectLevel.medium,
  );
  final image = QrImage(code);
  final count = image.moduleCount;
  final size = (count + quiet * 2) * moduleSize;
  final buffer = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" '
    'viewBox="0 0 $size $size" shape-rendering="crispEdges" role="img" '
    'aria-label="QR de pareamento">',
  );
  buffer.write('<rect width="$size" height="$size" fill="#ffffff"/>');
  for (var row = 0; row < count; row++) {
    for (var col = 0; col < count; col++) {
      if (!image.isDark(row, col)) continue;
      final x = (col + quiet) * moduleSize;
      final y = (row + quiet) * moduleSize;
      buffer.write(
        '<rect x="$x" y="$y" width="$moduleSize" height="$moduleSize" '
        'fill="#101010"/>',
      );
    }
  }
  buffer.write('</svg>');
  return buffer.toString();
}

const _i18nScript = r'''
<script>
const S2P_DICT = {
  pt: {
    pageTitle: 'Stick2Planner · Pareamento',
    loginTitle: 'Stick2Planner · Pareamento',
    loginHelp: 'Informe o token administrativo (ADMIN_TOKEN) para ver o QR e os dispositivos pareados.',
    loginButton: 'Entrar',
    loginInvalid: 'Token administrativo inválido.',
    pairing: 'Pareamento',
    pairingHelp: 'Escaneie o QR no app ou copie o código abaixo. O código é renovado enquanto esta página estiver aberta.',
    generating: 'gerando…',
    newCode: 'Novo código',
    pairingCode: 'Código de pareamento',
    copyCode: 'Copiar código',
    logout: 'Sair',
    devices: 'Dispositivos pareados',
    device: 'Dispositivo',
    lastAccess: 'Último acesso',
    state: 'Estado',
    loading: 'carregando…',
    noDevices: 'nenhum dispositivo',
    revokeNote: 'Revogar remove o acesso do token imediatamente; o dispositivo pode ser pareado de novo.',
    active: 'ativo',
    revoked: 'revogado',
    rename: 'Renomear',
    revoke: 'Revogar',
    renamePrompt: 'Novo nome do dispositivo',
    expiresIn: 'expira em {n}s',
    expired: 'expirado',
    switchTo: 'English'
  },
  en: {
    pageTitle: 'Stick2Planner · Pairing',
    loginTitle: 'Stick2Planner · Pairing',
    loginHelp: 'Enter the admin token (ADMIN_TOKEN) to see the QR code and paired devices.',
    loginButton: 'Sign in',
    loginInvalid: 'Invalid admin token.',
    pairing: 'Pairing',
    pairingHelp: 'Scan the QR in the app or copy the code below. The code refreshes while this page stays open.',
    generating: 'generating…',
    newCode: 'New code',
    pairingCode: 'Pairing code',
    copyCode: 'Copy code',
    logout: 'Sign out',
    devices: 'Paired devices',
    device: 'Device',
    lastAccess: 'Last access',
    state: 'Status',
    loading: 'loading…',
    noDevices: 'no devices',
    revokeNote: 'Revoking removes token access immediately; the device can be paired again.',
    active: 'active',
    revoked: 'revoked',
    rename: 'Rename',
    revoke: 'Revoke',
    renamePrompt: 'New device name',
    expiresIn: 'expires in {n}s',
    expired: 'expired',
    switchTo: 'Português'
  }
};
const saved = localStorage.getItem('s2p-lang');
const browserLang = (navigator.language || 'pt').toLowerCase();
let LANG = saved === 'pt' || saved === 'en'
  ? saved
  : (browserLang.startsWith('pt') ? 'pt' : 'en');
function t(key, vars) {
  let text = (S2P_DICT[LANG] && S2P_DICT[LANG][key]) || S2P_DICT.pt[key] || key;
  if (vars) Object.keys(vars).forEach((k) => {
    text = text.split('{' + k + '}').join(vars[k]);
  });
  return text;
}
function applyLang() {
  document.documentElement.lang = LANG === 'pt' ? 'pt-BR' : 'en';
  const titleKey = document.body.dataset.i18nTitle;
  if (titleKey) document.title = t(titleKey);
  document.querySelectorAll('[data-i18n]').forEach((el) => {
    el.textContent = t(el.dataset.i18n);
  });
  document.querySelectorAll('[data-i18n-aria]').forEach((el) => {
    el.setAttribute('aria-label', t(el.dataset.i18nAria));
  });
  document.querySelectorAll('[data-lang-toggle]').forEach((el) => {
    el.textContent = t('switchTo');
  });
}
function toggleLang() {
  LANG = LANG === 'pt' ? 'en' : 'pt';
  try { localStorage.setItem('s2p-lang', LANG); } catch (_) {}
  applyLang();
  if (window.onLangChange) window.onLangChange();
}
document.querySelectorAll('[data-lang-toggle]').forEach((el) => {
  el.onclick = toggleLang;
});
applyLang();
</script>
''';

String _loginHtml({bool invalid = false}) =>
    '''
<!doctype html>
<html lang="pt-BR"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Stick2Planner · Pareamento</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; min-height:100vh; display:grid; place-items:center;
    background: radial-gradient(1200px 600px at 20% 0%, #12352a, #0b1411 60%);
    color:#e7f2ed; font:16px/1.5 system-ui, sans-serif; }
  form { width:min(440px, 92vw); background:#121c18cc; border:1px solid #2a3a33;
    border-radius:16px; padding:28px; box-shadow:0 18px 60px #0008; }
  .head { display:flex; align-items:center; justify-content:space-between; gap:12px; }
  h1 { font-size:20px; margin:0 0 8px; }
  p { margin:0 0 18px; color:#a9bdb4; font-size:14px; }
  input { width:100%; box-sizing:border-box; padding:12px 14px; border-radius:10px;
    border:1px solid #355047; background:#0d1613; color:#e7f2ed; font-size:15px; }
  button { margin-top:14px; width:100%; padding:12px 14px; border:0; border-radius:10px;
    background:#59d3a2; color:#062018; font-weight:700; font-size:15px; cursor:pointer; }
  button.lang { width:auto; margin:0; padding:8px 10px; background:transparent;
    color:#8ff0c4; border:1px solid #355047; font-weight:600; font-size:13px; }
  .err { color:#ff9d9d; margin:0 0 14px; font-size:14px; }
</style></head><body data-i18n-title="pageTitle">
<form method="post" action="/login">
  <div class="head">
    <h1 data-i18n="loginTitle">Stick2Planner · Pareamento</h1>
    <button type="button" class="lang" data-lang-toggle>English</button>
  </div>
  <p data-i18n="loginHelp">Informe o token administrativo (ADMIN_TOKEN) para ver o QR e os
     dispositivos pareados.</p>
  ${invalid ? '<p class="err" data-i18n="loginInvalid">Token administrativo inválido.</p>' : ''}
  <input type="password" name="token" placeholder="ADMIN_TOKEN" autofocus required>
  <button type="submit" data-i18n="loginButton">Entrar</button>
</form>
$_i18nScript
</body></html>
''';

String _dashboardHtml({required String serverId}) =>
    '''
<!doctype html>
<html lang="pt-BR"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Stick2Planner · Pareamento</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; padding:28px 18px; background:
    radial-gradient(1400px 700px at 10% 0%, #12352a, #0b1411 55%);
    color:#e7f2ed; font:16px/1.5 system-ui, sans-serif; }
  main { max-width:1050px; margin:0 auto; display:grid; gap:20px;
    grid-template-columns:minmax(280px, 380px) 1fr; }
  @media (max-width: 820px) and (orientation: portrait) {
    main { grid-template-columns:1fr; }
  }
  @media (orientation: landscape) and (max-height: 700px) {
    body { padding:16px 18px; }
    main { max-width:1100px; gap:14px; align-items:start;
      grid-template-columns:minmax(220px, 320px) 1fr; }
    .card { padding:14px; }
    h1 { font-size:18px; }
    h2 { margin-bottom:10px; }
    .sub { margin-bottom:10px; }
    .qr { max-width:220px; margin:0 auto; }
    button { font-size:13px; padding:8px 12px; }
    textarea { height:46px; }
  }
  @media (orientation: landscape) and (max-width: 559px) {
    main { grid-template-columns:1fr; }
  }
  @media (orientation: landscape) and (max-height: 480px) {
    .sub { display:none; }
    .qr { max-width:150px; }
    textarea { height:40px; }
    .actions { margin-top:8px; }
  }
  .card { background:#121c18cc; border:1px solid #2a3a33; border-radius:16px;
    padding:20px; }
  h1 { font-size:20px; margin:0 0 4px; }
  h2 { font-size:15px; margin:0 0 14px; color:#bfd4ca; font-weight:600; }
  .sub { color:#93a89e; font-size:13px; margin:0 0 16px; }
  .qr { background:#fff; border-radius:12px; padding:14px; aspect-ratio:1; }
  .qr svg { display:block; width:100%; height:100%; }
  .row { display:flex; justify-content:space-between; align-items:center; gap:12px; }
  .pill { font-size:12px; padding:4px 10px; border-radius:999px;
    background:#1b3a2e; color:#8ff0c4; border:1px solid #2f6b52; }
  code, textarea { font-family:ui-monospace, monospace; font-size:12px; }
  textarea { width:100%; box-sizing:border-box; height:54px; resize:vertical;
    background:#0d1613; color:#cfe6dc; border:1px solid #2f4a40; border-radius:10px;
    padding:8px; }
  button { padding:9px 14px; border-radius:10px; border:1px solid #355047;
    background:#16241f; color:#d9eee5; cursor:pointer; font-size:14px; }
  button.primary { background:#59d3a2; color:#062018; border-color:#59d3a2;
    font-weight:700; }
  button.danger { border-color:#6d3232; color:#ffadad; background:#221314; }
  button.lang { padding:7px 10px; background:transparent; color:#8ff0c4;
    font-weight:600; font-size:13px; }
  table { width:100%; border-collapse:collapse; font-size:14px; }
  th, td { text-align:left; padding:9px 6px; border-bottom:1px solid #22332c; }
  th { color:#93a89e; font-weight:600; font-size:12px; text-transform:uppercase;
    letter-spacing:.04em; }
  .muted { color:#7f948b; font-size:12px; }
  .actions { display:flex; gap:10px; flex-wrap:wrap; margin-top:12px; }
</style></head><body data-i18n-title="pageTitle">
<main>
  <section class="card">
    <div class="row">
      <h1 data-i18n="pairing">Pareamento</h1>
      <div class="row" style="gap:8px">
        <span class="pill" id="server">$serverId</span>
        <button type="button" class="lang" data-lang-toggle>English</button>
      </div>
    </div>
    <p class="sub" data-i18n="pairingHelp">Escaneie o QR no app ou copie o código abaixo. O código é
       renovado enquanto esta página estiver aberta.</p>
    <div class="qr" id="qr"></div>
    <div class="row" style="margin-top:12px">
      <span class="muted" id="countdown" data-i18n="generating">gerando…</span>
      <button id="refresh" data-i18n="newCode">Novo código</button>
    </div>
    <textarea id="code" readonly aria-label="Código de pareamento"
      data-i18n-aria="pairingCode"></textarea>
    <div class="actions">
      <button class="primary" id="copy" data-i18n="copyCode">Copiar código</button>
      <form method="post" action="/logout"><button class="danger" data-i18n="logout">Sair</button></form>
    </div>
  </section>
  <section class="card">
    <h2 data-i18n="devices">Dispositivos pareados</h2>
    <table><thead><tr>
      <th data-i18n="device">Dispositivo</th>
      <th data-i18n="lastAccess">Último acesso</th>
      <th data-i18n="state">Estado</th><th></th>
    </tr></thead>
      <tbody id="devices"><tr><td colspan="4" class="muted" data-i18n="loading">carregando…</td></tr></tbody>
    </table>
    <p class="muted" style="margin-top:12px" data-i18n="revokeNote">Revogar remove o acesso do token
       imediatamente; o dispositivo pode ser pareado de novo.</p>
  </section>
</main>
$_i18nScript
<script>
let expiresAt = 0, refreshTimer = null;
const qr = document.getElementById('qr');
const code = document.getElementById('code');
const countdown = document.getElementById('countdown');
document.getElementById('refresh').onclick = loadPairing;
document.getElementById('copy').onclick = async () => {
  try { await navigator.clipboard.writeText(code.value); } catch (_) { code.select(); }
};
window.onLangChange = () => {
  tick();
  loadDevices();
};
async function loadPairing() {
  const res = await fetch('/api/pairing', {cache:'no-store'});
  if (!res.ok) { location = '/'; return; }
  const data = await res.json();
  qr.innerHTML = data.svg;
  code.value = data.url + '|' + data.pairingToken;
  expiresAt = Date.now() + data.ttlMs;
  clearTimeout(refreshTimer);
  refreshTimer = setTimeout(loadPairing, Math.max(5000, data.ttlMs - 30000));
  tick();
}
function tick() {
  const left = Math.max(0, Math.round((expiresAt - Date.now()) / 1000));
  countdown.textContent = left > 0 ? t('expiresIn', {n: left}) : t('expired');
  if (left === 0) loadPairing();
}
async function loadDevices() {
  const res = await fetch('/api/devices', {cache:'no-store'});
  if (!res.ok) { location = '/'; return; }
  const data = await res.json();
  const body = document.getElementById('devices');
  if (!data.devices.length) {
    body.innerHTML = '<tr><td colspan="4" class="muted">' + escapeHtml(t('noDevices')) + '</td></tr>';
    return;
  }
  body.innerHTML = data.devices.map((d) => {
    const seen = d.lastSeenAt ? new Date(d.lastSeenAt).toLocaleString() : '—';
    const state = d.revokedAt ? t('revoked') : t('active');
    const action = d.revokedAt ? '' :
      '<button data-rename="' + d.deviceId + '">' + escapeHtml(t('rename')) + '</button> ' +
      '<button class="danger" data-id="' + d.deviceId + '">' + escapeHtml(t('revoke')) + '</button>';
    return '<tr><td>' + escapeHtml(d.label) + '<div class="muted">' +
      escapeHtml(d.deviceId) + '</div></td><td>' + seen + '</td><td>' + state +
      '</td><td>' + action + '</td></tr>';
  }).join('');
  body.querySelectorAll('button[data-rename]').forEach((button) => {
    button.onclick = async () => {
      const label = prompt(t('renamePrompt'), '');
      if (!label || !label.trim()) return;
      await fetch('/api/devices/' + encodeURIComponent(button.dataset.rename) + '/label',
        {method:'POST', headers:{'content-type':'application/json'},
         body: JSON.stringify({label: label.trim()})});
      loadDevices();
    };
  });
  body.querySelectorAll('button[data-id]').forEach((button) => {
    button.onclick = async () => {
      await fetch('/api/devices/' + encodeURIComponent(button.dataset.id) + '/revoke',
        {method:'POST'});
      loadDevices();
    };
  });
}
function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
  }[c]));
}
loadPairing();
loadDevices();
setInterval(tick, 1000);
setInterval(loadDevices, 5000);
</script>
</body></html>
''';
