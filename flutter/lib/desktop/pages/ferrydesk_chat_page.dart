import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';

const _bg = Color(0xFF1F2128);
const _panel = Color(0xFF14151A);
const _panelAlt = Color(0xFF1A1C22);
const _bubbleOp = Color(0xFF2A2D36);
const _accent = Color(0xFFFECD08);
const _green = Color(0xFF22C55E);
const _red = Color(0xFFEF4444);

const _wsBase = 'wss://ferrydesk.com/ws/chat';
const _apiBase = 'https://ferrydesk.com';
const _kAccessTokenKey = 'ferrydesk_access_token';
const _kUserJsonKey = 'ferrydesk_user_json';
const _kInstallDeclinedKey = 'ferrydesk_install_declined';
// Pre-rebrand keys; read-only fallback so users carrying state from the
// FerryDesk build keep their session and "don't ask" install choice.
const _kLegacyAccessTokenKey = 'ferrydesk_access_token';
const _kLegacyUserJsonKey = 'ferrydesk_user_json';
const _kLegacyInstallDeclinedKey = 'ferrydesk_install_declined';

String _readMigrated(String newKey, String legacyKey) {
  final v = bind.mainGetLocalOption(key: newKey);
  if (v.isNotEmpty) return v;
  return bind.mainGetLocalOption(key: legacyKey);
}

class FerryDeskChatPage extends StatefulWidget {
  const FerryDeskChatPage({Key? key}) : super(key: key);

  @override
  State<FerryDeskChatPage> createState() => _FerryDeskChatPageState();
}

// Rendezvous service status the dot displays.
// Green = rustdesk service is connected to the relay/rendezvous server, which
// is what makes this device reachable from the FerryDesk dashboard. This is
// independent of login state and independent of the chat WebSocket — both of
// which can be down without the device being "offline" in the meaningful sense.
enum _SvcStatus { notReady, connecting, ready }

class _FerryDeskChatPageState extends State<FerryDeskChatPage> with WindowListener {
  WebSocketChannel? _ws;
  bool _wsConnected = false;
  _SvcStatus _svc = _SvcStatus.connecting;
  String _machineId = '';
  String _machineUuid = '';
  // Temporary password surfaced for fallback when an operator can't reach
  // the machine via the auto-accept path (e.g. ferrydesk_auto_accept=N or
  // server-side prep flow not used). Auto-rotates per RustDesk schedule;
  // refreshed on every status poll tick.
  String _password = '';
  // App version (from Cargo.toml via FFI). One-shot fetch on bootstrap;
  // doesn't change at runtime.
  String _version = '';
  Map<String, dynamic>? _user;
  final _messages = <_Msg>[];
  final _scroll = ScrollController();
  final _input = TextEditingController();
  Timer? _reconnect;
  Timer? _statusPoll;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _bootstrap();
    _startStatusPoll();
  }

  void _startStatusPoll() {
    _pollStatusOnce();
    _statusPoll =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollStatusOnce());
  }

  Future<void> _pollStatusOnce() async {
    try {
      final raw = await bind.mainGetConnectStatus();
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final n = m['status_num'];
      _SvcStatus next;
      if (n == 1) {
        next = _SvcStatus.ready;
      } else if (n == 0) {
        next = _SvcStatus.connecting;
      } else {
        next = _SvcStatus.notReady;
      }
      if (mounted && next != _svc) setState(() => _svc = next);
    } catch (_) {}
    try {
      final pw = await bind.mainGetTemporaryPassword();
      if (mounted && pw != _password) setState(() => _password = pw);
    } catch (_) {}
  }

  Future<void> _bootstrap() async {
    final id = await bind.mainGetMyId();
    final uuid = await bind.mainGetUuid();
    final version = await bind.mainGetVersion();
    final userJson = _readMigrated(_kUserJsonKey, _kLegacyUserJsonKey);
    Map<String, dynamic>? user;
    if (userJson.isNotEmpty) {
      try {
        user = jsonDecode(userJson) as Map<String, dynamic>;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _machineId = id;
      _machineUuid = uuid;
      _user = user;
      _version = version;
    });
    _connect();
    _maybeOfferInstall();
  }

  // Offer to install the app to Program Files on first run, only when:
  //   - Running on Windows
  //   - The current binary is not already an installed copy
  //   - The user hasn't previously chosen "Don't ask again"
  // Choosing Install re-execs with --install (handled by the upstream
  // InstallPage which the build still includes).
  Future<void> _maybeOfferInstall() async {
    if (!Platform.isWindows) return;
    try {
      if (bind.mainIsInstalled()) return;
    } catch (_) {
      return;
    }
    if (_readMigrated(_kInstallDeclinedKey, _kLegacyInstallDeclinedKey) == 'Y')
      return;
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: const Text(
          'Install FerryDesk Remote',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Install FerryDesk Remote to this PC?\n\nInstalling registers the app, '
          'launches it automatically when you sign in, and shows a tray icon '
          'next to the clock so you can chat without keeping a window open.\n\n'
          'You can keep running it portably if you prefer.',
          style: TextStyle(color: Colors.white70, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'never'),
            child: const Text("Don't ask again",
                style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: const Text('Not now',
                style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, 'install'),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (result == 'never') {
      await bind.mainSetLocalOption(
          key: _kInstallDeclinedKey, value: 'Y');
    } else if (result == 'install') {
      bind.mainGotoInstall();
    }
  }

  Future<void> _connect() async {
    if (_disposed || _machineId.isEmpty) return;
    _reconnect?.cancel();
    final WebSocketChannel ws;
    try {
      ws = WebSocketChannel.connect(
        Uri.parse('$_wsBase?machine_id=$_machineId&role=machine'),
      );
    } catch (_) {
      _drop();
      return;
    }
    _ws = ws;
    ws.stream.listen(
      _onIncoming,
      onError: (_) {
        if (_ws == ws) _drop();
      },
      onDone: () {
        if (_ws == ws) _drop();
      },
      cancelOnError: true,
    );
    try {
      await ws.ready;
    } catch (_) {
      if (_ws == ws) _drop();
      return;
    }
    if (!mounted || _disposed || _ws != ws) return;
    setState(() => _wsConnected = true);
  }

  void _drop() {
    _ws = null;
    if (mounted) setState(() => _wsConnected = false);
    if (_disposed) return;
    _reconnect = Timer(const Duration(seconds: 3), _connect);
  }

  void _onIncoming(dynamic raw) {
    try {
      final m = jsonDecode(raw as String) as Map<String, dynamic>;
      final t = (m['type'] ?? '').toString();
      if (t == 'message') {
        final text = (m['text'] ?? '').toString();
        if (text.isEmpty) return;
        final fromName = (m['from_name'] ?? 'Operator').toString();
        if (!mounted) return;
        setState(() {
          _messages.add(_Msg(
            text: text,
            fromOperator: true,
            fromName: fromName,
            ts: DateTime.now(),
          ));
        });
        _scrollToBottom();
        _alertUser();
      } else if (t == 'screenshot_request') {
        final reqId = (m['request_id'] ?? '').toString();
        _handleScreenshotRequest(reqId);
      }
    } catch (_) {}
  }

  // Operator clicked "Take screenshot" in the dashboard. Capture one frame
  // via the Rust scrap path, send it back over the same WS as a
  // `screenshot_response` keyed by request_id.
  Future<void> _handleScreenshotRequest(String requestId) async {
    if (requestId.isEmpty) return;
    final ws = _ws;
    if (ws == null) return;
    final b64 = await bind.ferrydeskCaptureScreenshot();
    if (b64.isEmpty) {
      ws.sink.add(jsonEncode({
        'type': 'screenshot_response',
        'request_id': requestId,
        'error': 'capture_failed',
      }));
      return;
    }
    ws.sink.add(jsonEncode({
      'type': 'screenshot_response',
      'request_id': requestId,
      'format': 'jpeg',
      'data': b64,
    }));
  }

  // Bring the chat window to the foreground when a new operator message
  // arrives. Restores from minimized, shows from hidden, focuses always.
  // Plays a soft system alert sound on Windows/macOS.
  Future<void> _alertUser() async {
    try {
      final visible = await windowManager.isVisible();
      final minimized = await windowManager.isMinimized();
      if (minimized) {
        await windowManager.restore();
      } else if (!visible) {
        await windowManager.show();
      }
      await windowManager.focus();
    } catch (_) {}
    SystemSound.play(SystemSoundType.alert);
  }

  Future<({bool ok, String? error})> _doLogin(
      String username, String password) async {
    if (_machineId.isEmpty) {
      return (ok: false, error: 'Machine ID not ready, try again in a moment.');
    }
    final body = jsonEncode({
      'username': username,
      'password': password,
      'id': _machineId,
      'uuid': _machineUuid,
      'autoLogin': true,
      'type': 'account',
      'deviceInfo': {
        'name': Platform.localHostname,
        'os': '${Platform.operatingSystem} / ${Platform.operatingSystemVersion}',
      },
    });
    final http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$_apiBase/api/login'),
            headers: const {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      return (ok: false, error: 'Network error.');
    }
    if (resp.statusCode == 429) {
      return (ok: false, error: 'Too many attempts. Try again later.');
    }
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return (ok: false, error: 'Server returned an unexpected response.');
    }
    final err = parsed['error'];
    if (err is String && err.isNotEmpty) {
      return (ok: false, error: err);
    }
    final token = parsed['access_token'];
    final user = parsed['user'];
    if (token is! String || token.isEmpty || user is! Map<String, dynamic>) {
      return (ok: false, error: 'Server response missing token.');
    }
    await bind.mainSetLocalOption(key: _kAccessTokenKey, value: token);
    await bind.mainSetLocalOption(
        key: _kUserJsonKey, value: jsonEncode(user));
    // Clear legacy keys so they can't shadow new state if the new write fails
    // mid-flow.
    await bind.mainSetLocalOption(key: _kLegacyAccessTokenKey, value: '');
    await bind.mainSetLocalOption(key: _kLegacyUserJsonKey, value: '');
    if (mounted) setState(() => _user = user);
    return (ok: true, error: null);
  }

  Future<void> _doLogout() async {
    final token = _readMigrated(_kAccessTokenKey, _kLegacyAccessTokenKey);
    // Clear locally first so a slow /logout doesn't keep the user "logged in"
    // visually if the server is unreachable. Clear both new and legacy keys.
    await bind.mainSetLocalOption(key: _kAccessTokenKey, value: '');
    await bind.mainSetLocalOption(key: _kUserJsonKey, value: '');
    await bind.mainSetLocalOption(key: _kLegacyAccessTokenKey, value: '');
    await bind.mainSetLocalOption(key: _kLegacyUserJsonKey, value: '');
    if (mounted) setState(() => _user = null);
    if (token.isEmpty) return;
    try {
      await http
          .post(
            Uri.parse('$_apiBase/api/logout'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'id': _machineId, 'uuid': _machineUuid}),
          )
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // best-effort; local logout already done
    }
  }

  void _send() {
    final text = _input.text.trim();
    final ws = _ws;
    if (text.isEmpty || ws == null) return;
    ws.sink.add(jsonEncode({'type': 'message', 'text': text}));
    setState(() {
      _messages.add(_Msg(
        text: text,
        fromOperator: false,
        fromName: 'You',
        ts: DateTime.now(),
      ));
      _input.clear();
    });
    _scrollToBottom();
  }

  Future<void> _showLoginDialog() async {
    final emailCtl = TextEditingController();
    final pwCtl = TextEditingController();
    String? err;
    bool busy = false;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Dialog(
          backgroundColor: _panel,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Sign in to FerryDesk',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _DialogField(
                    controller: emailCtl,
                    label: 'Email or username',
                    autofocus: true,
                    enabled: !busy,
                  ),
                  const SizedBox(height: 12),
                  _DialogField(
                    controller: pwCtl,
                    label: 'Password',
                    obscure: true,
                    enabled: !busy,
                    onSubmit: () async {
                      // Submit via Enter
                    },
                  ),
                  if (err != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      err!,
                      style: const TextStyle(color: _red, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: busy ? null : () => Navigator.pop(ctx),
                        child: const Text('Cancel',
                            style: TextStyle(color: Colors.white60)),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 22, vertical: 12),
                        ),
                        onPressed: busy
                            ? null
                            : () async {
                                final u = emailCtl.text.trim();
                                final p = pwCtl.text;
                                if (u.isEmpty || p.isEmpty) {
                                  setLocal(() =>
                                      err = 'Enter both email and password.');
                                  return;
                                }
                                setLocal(() {
                                  busy = true;
                                  err = null;
                                });
                                final result = await _doLogin(u, p);
                                if (!ctx.mounted) return;
                                if (result.ok) {
                                  Navigator.pop(ctx);
                                } else {
                                  setLocal(() {
                                    busy = false;
                                    err = result.error;
                                  });
                                }
                              },
                        child: busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Text('Sign in'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    emailCtl.dispose();
    pwCtl.dispose();
  }

  Future<void> _showLogoutMenu() async {
    final user = _user;
    if (user == null) return;
    final name = (user['display_name'] ?? user['name'] ?? '').toString();
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('Sign out',
            style: TextStyle(color: Colors.white)),
        content: Text(
          name.isEmpty
              ? 'Sign out of FerryDesk?'
              : 'Sign out of $name?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white60)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out',
                style: TextStyle(color: _red)),
          ),
        ],
      ),
    );
    if (shouldLogout == true) {
      await _doLogout();
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 50), () {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  @override
  void dispose() {
    _disposed = true;
    windowManager.removeListener(this);
    _reconnect?.cancel();
    _statusPoll?.cancel();
    _ws?.sink.close();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          _header(),
          _idStrip(),
          Expanded(child: _chatList()),
          _inputBar(),
        ],
      ),
    );
  }

  Widget _header() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: _panel,
        child: Row(
          children: [
            Image.asset('assets/icon.png', width: 28, height: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Text(
                    'FerryDesk Remote',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_version.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      'v$_version',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _statusColor(),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _statusLabel(),
              style: TextStyle(
                color: _statusColor(),
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 12),
            _AccountBtn(
              user: _user,
              onLoginTap: _showLoginDialog,
              onLogoutTap: _showLogoutMenu,
            ),
            // Windows uses in-window minimize/hide because it has no system-
            // managed window chrome. macOS has native traffic-light controls
            // at top-left for the same actions, so rendering custom in-window
            // ones there is redundant and visually noisy. Keep the
            // Platform.isWindows guard.
            if (Platform.isWindows) ...[
              const SizedBox(width: 4),
              _IconBtn(
                icon: Icons.remove,
                tooltip: 'Minimize',
                onTap: () => windowManager.minimize(),
              ),
              const SizedBox(width: 4),
              _IconBtn(
                icon: Icons.close,
                tooltip: 'Hide to tray',
                onTap: () => windowManager.hide(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _idStrip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: _panelAlt,
      child: Row(
        children: [
          const Text(
            'ID:',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
          const SizedBox(width: 6),
          SelectableText(
            _machineId.isEmpty ? '...' : _formatId(_machineId),
            style: const TextStyle(
              color: _accent,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 20),
          const Text(
            'Password:',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
          const SizedBox(width: 6),
          SelectableText(
            _password.isEmpty ? '—' : _password,
            style: const TextStyle(
              color: _accent,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  // Format a 9-digit RustDesk ID as "XXX XXX XXX" for readability.
  // Returns the input unchanged for any other length so partial / placeholder
  // states still render (e.g. while the FFI fetch is in flight).
  String _formatId(String id) {
    if (id.length != 9) return id;
    return '${id.substring(0, 3)} ${id.substring(3, 6)} ${id.substring(6, 9)}';
  }

  Color _statusColor() {
    switch (_svc) {
      case _SvcStatus.ready:
        return _green;
      case _SvcStatus.connecting:
        return _accent;
      case _SvcStatus.notReady:
        return _red;
    }
  }

  String _statusLabel() {
    switch (_svc) {
      case _SvcStatus.ready:
        return 'Online';
      case _SvcStatus.connecting:
        return 'Connecting…';
      case _SvcStatus.notReady:
        return 'Offline';
    }
  }

  Widget _chatList() {
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _svc == _SvcStatus.ready
                ? 'No messages yet.\nWaiting for an operator to reach out.'
                : _svc == _SvcStatus.connecting
                    ? 'Connecting to FerryDesk…'
                    : 'Offline. The app will reconnect automatically.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      itemCount: _messages.length,
      itemBuilder: (_, i) => _bubble(_messages[i]),
    );
  }

  Widget _bubble(_Msg m) {
    final maxW = MediaQuery.of(context).size.width * 0.72;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: m.fromOperator ? Alignment.centerLeft : Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: maxW),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: m.fromOperator ? _bubbleOp : _accent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.fromOperator)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    m.fromName,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Text(
                m.text,
                style: TextStyle(
                  color: m.fromOperator ? Colors.white : Colors.black,
                  fontSize: 14,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: const BoxDecoration(
        color: _panel,
        border: Border(top: BorderSide(color: Color(0xFF2A2D36))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              maxLines: 4,
              minLines: 1,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: _wsConnected
                    ? 'Type a message...'
                    : 'Type a message... (chat unavailable)',
                hintStyle: const TextStyle(color: Colors.white30),
                filled: true,
                fillColor: _bg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: _wsConnected ? _accent : _bubbleOp,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _send,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(
                  Icons.send,
                  color: _wsConnected ? Colors.black : Colors.white38,
                  size: 18,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Msg {
  final String text;
  final bool fromOperator;
  final String fromName;
  final DateTime ts;
  _Msg({
    required this.text,
    required this.fromOperator,
    required this.fromName,
    required this.ts,
  });
}

class _AccountBtn extends StatelessWidget {
  final Map<String, dynamic>? user;
  final VoidCallback onLoginTap;
  final VoidCallback onLogoutTap;
  const _AccountBtn({
    required this.user,
    required this.onLoginTap,
    required this.onLogoutTap,
  });

  String _initials() {
    final u = user;
    if (u == null) return '?';
    final raw =
        ((u['display_name'] ?? u['name'] ?? u['email'] ?? '') as Object?)
            .toString();
    if (raw.isEmpty) return '?';
    final parts = raw.split(RegExp(r'\s+|@')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final logged = user != null;
    final tip = logged
        ? '${(user!['display_name'] ?? user!['name'] ?? '').toString()} — sign out'
        : 'Sign in';
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: logged ? onLogoutTap : onLoginTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: logged ? _accent : _bubbleOp,
          ),
          child: logged
              ? Text(
                  _initials(),
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                )
              : const Icon(Icons.person_outline,
                  color: Colors.white70, size: 16),
        ),
      ),
    );
  }
}

class _DialogField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscure;
  final bool autofocus;
  final bool enabled;
  final VoidCallback? onSubmit;
  const _DialogField({
    required this.controller,
    required this.label,
    this.obscure = false,
    this.autofocus = false,
    this.enabled = true,
    this.onSubmit,
  });
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autofocus: autofocus,
      enabled: enabled,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54, fontSize: 13),
        filled: true,
        fillColor: _bg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _accent, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      onSubmitted: onSubmit == null ? null : (_) => onSubmit!(),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 18,
  });
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: Colors.white70, size: size),
        ),
      ),
    );
  }
}
