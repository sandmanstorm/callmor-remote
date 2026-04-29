import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img_lib;
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart';

import '../../models/platform_model.dart';

const _kPreviewsOptionKey = 'callmor-screenshots-enabled';
const MethodChannel _kHostChannel = MethodChannel('org.rustdesk.rustdesk/host');

const _kBrandNavy = Color(0xFF0F3D92);
const _kBrandYellow = Color(0xFFFFC72C);
const _kBgDark = Color(0xFF14141A);
const _kPanelDark = Color(0xFF1C1D24);
const _kCardDark = Color(0xFF24252E);
const _kTextSecondary = Color(0xFF9AA0AB);
const _kHairline = Color(0xFF2A2C36);

const _kApiBase = 'https://remote.callmor.ai';
const _kWsBase = 'wss://remote.callmor.ai';

class CallmorChatPage extends StatefulWidget {
  const CallmorChatPage({super.key});

  @override
  State<CallmorChatPage> createState() => _CallmorChatPageState();
}

class _CallmorChatPageState extends State<CallmorChatPage>
    with WindowListener, tray.TrayListener {
  final _composer = TextEditingController();
  final _messages = <_ChatMsg>[];
  final _scroll = ScrollController();

  String _id = '';
  _ConnState _conn = _ConnState.connecting;
  Timer? _statusTimer;
  WebSocketChannel? _ws;

  String? _token;
  String? _userName;
  String? _userEmail;
  bool _idCopied = false;

  bool _previewsEnabled = true;
  bool _captureInFlight = false;

  String? _historyPath;
  // Mute incoming WS frames briefly after a fresh connect, to swallow the
  // server's history-replay burst (it doesn't tag direction).
  DateTime _wsConnectedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _kHistoryReplayMuteMs = 2500;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _refreshId();
    _refreshStatus();
    _loadPreviewsFlag();
    _statusTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _refreshStatus());
  }

  Future<void> _loadHistory() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _historyPath = '${dir.path}/callmor_chat.json';
      final f = File(_historyPath!);
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final loaded = list
          .map((m) => _ChatMsg(
                text: (m['text'] ?? '').toString(),
                fromMe: m['fromMe'] == true,
                ts: DateTime.fromMillisecondsSinceEpoch(
                    (m['ts'] ?? 0) as int),
              ))
          .where((m) => m.text.isNotEmpty)
          .toList();
      if (!mounted || loaded.isEmpty) return;
      setState(() => _messages.addAll(loaded));
      _scrollToEnd();
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    if (_historyPath == null) return;
    try {
      final keep = _messages.length > 500
          ? _messages.sublist(_messages.length - 500)
          : _messages;
      final json = jsonEncode(keep
          .map((m) => {
                'text': m.text,
                'fromMe': m.fromMe,
                'ts': m.ts.millisecondsSinceEpoch,
              })
          .toList());
      await File(_historyPath!).writeAsString(json);
    } catch (_) {}
  }

  bool _isLikelyDuplicateOfRecent(String text, bool fromMe) {
    // Server may replay history right after WS reconnect. If the same text
    // already exists in the last few hundred messages on the same side,
    // suppress the duplicate.
    final tail =
        _messages.length > 400 ? _messages.sublist(_messages.length - 400) : _messages;
    for (final m in tail.reversed) {
      if (m.text == text && m.fromMe == fromMe) return true;
    }
    return false;
  }

  Future<void> _loadPreviewsFlag() async {
    try {
      final v = await bind.mainGetOption(key: _kPreviewsOptionKey);
      if (mounted) {
        setState(() => _previewsEnabled = v != 'N');
      }
    } catch (_) {}
  }

  void _setPreviewsFlag(bool enabled) {
    setState(() => _previewsEnabled = enabled);
    try {
      bind.mainSetOption(key: _kPreviewsOptionKey, value: enabled ? '' : 'N');
    } catch (_) {}
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _ws?.sink.close();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refreshId() async {
    try {
      final id = await bind.mainGetMyId();
      if (id.isEmpty) return;
      if (id != _id) {
        setState(() => _id = id);
        _connectChat();
      }
    } catch (_) {}
  }

  Future<void> _refreshStatus() async {
    try {
      await bind.mainCheckConnectStatus();
      final raw = await bind.mainGetConnectStatus();
      if (raw.isEmpty) return;
      final j = jsonDecode(raw);
      final n = (j['status_num'] ?? 0) as int;
      _ConnState next;
      if (n > 0) {
        next = _ConnState.online;
      } else if (n < 0) {
        next = _ConnState.offline;
      } else {
        next = _ConnState.connecting;
      }
      if (next != _conn) setState(() => _conn = next);
      if (_id.isEmpty) await _refreshId();
    } catch (_) {}
  }

  void _connectChat() {
    if (_id.isEmpty) return;
    _ws?.sink.close();
    try {
      final uri = Uri.parse('$_kWsBase/ws/chat?machine_id=$_id&role=machine');
      debugPrint('[Callmor chat] connecting WS: $uri');
      final ch = WebSocketChannel.connect(uri);
      _ws = ch;
      _wsConnectedAt = DateTime.now();
      ch.stream.listen(
        (event) {
          final raw = event.toString();
          debugPrint('[Callmor chat] WS recv: $raw');
          try {
            final m = jsonDecode(raw);
            final type = (m['type'] ?? m['event'] ?? '').toString();
            // Screenshot-on-demand: dashboard "Preview" button → capture and ship back.
            if (type == 'screenshot_request') {
              final reqId = (m['request_id'] ?? '').toString();
              _handleScreenshotRequest(reqId);
              return;
            }
            // The web → mac path works, so the server's frame shape arrives here.
            // Look at every common message-bearing field.
            final body = (m['body'] ??
                    m['text'] ??
                    m['message'] ??
                    m['msg'] ??
                    m['content'] ??
                    '')
                .toString();
            // Skip echoes of our own outgoing messages so we don't double them.
            final from = (m['from'] ?? m['role'] ?? m['sender'] ?? '').toString();
            if (from == 'machine' || from == 'self') return;
            if (body.isEmpty) return;
            // Drop the history-replay burst right after (re)connect — the
            // server doesn't tag direction, so it would all land on the
            // "received" side. We rely on the locally-persisted store
            // for cross-launch history instead.
            final sinceConnect = DateTime.now()
                .difference(_wsConnectedAt)
                .inMilliseconds;
            if (sinceConnect < _kHistoryReplayMuteMs) {
              debugPrint('[Callmor chat] suppressing replay frame ($sinceConnect ms after connect)');
              return;
            }
            // De-duplicate against locally-stored or in-session messages.
            if (_isLikelyDuplicateOfRecent(body, false)) return;
            setState(() {
              _messages.add(_ChatMsg(text: body, fromMe: false, ts: DateTime.now()));
            });
            _scrollToEnd();
            _saveHistory();
            // Bring the app and chat window to the foreground so the user
            // sees the new message even if they had hidden the window.
            _bringToFront();
          } catch (_) {}
        },
        onError: (e) => debugPrint('[Callmor chat] WS error: $e'),
        onDone: () => debugPrint('[Callmor chat] WS closed'),
      );
    } catch (e) {
      debugPrint('[Callmor chat] WS connect failed: $e');
    }
  }

  void _send() {
    final t = _composer.text.trim();
    if (t.isEmpty) return;
    setState(() {
      _messages.add(_ChatMsg(text: t, fromMe: true, ts: DateTime.now()));
      _composer.clear();
    });
    _scrollToEnd();
    _saveHistory();
    // Build a permissive payload with every common field a chat server might
    // route on. The web→mac path works, so the WS itself is fine; the server
    // just needs the right field/direction hint to forward to the web peer.
    final ts = DateTime.now().millisecondsSinceEpoch;
    final payload = {
      'type': 'message',
      'event': 'message',
      'machine_id': _id,
      'conversation_id': _id,
      'room': _id,
      'role': 'machine',
      'from': 'machine',
      'sender': 'machine',
      'direction': 'machine_to_web',
      'to': 'web',
      'text': t,
      'body': t,
      'message': t,
      'content': t,
      'persist': true,
      'save': true,
      'timestamp': ts,
    };
    debugPrint('[Callmor chat] WS send: ${jsonEncode(payload)}');
    try {
      _ws?.sink.add(jsonEncode(payload));
      // Also send a HTTP POST fallback (some servers split inbound messages
      // onto a REST endpoint and only stream outbound over WS).
      final auth = _token == null ? <String, String>{} : {'Authorization': 'Bearer $_token'};
      http.post(
        Uri.parse('$_kApiBase/api/messages'),
        headers: {'Content-Type': 'application/json', ...auth},
        body: jsonEncode({
          'machine_id': _id,
          'from': 'machine',
          'direction': 'machine_to_web',
          'text': t,
        }),
      ).timeout(const Duration(seconds: 5)).catchError((_) {
        return http.Response('', 0);
      });
    } catch (e) {
      debugPrint('[Callmor chat] send failed: $e');
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut);
    });
  }

  Future<void> _copyId() async {
    if (_id.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _id));
    setState(() => _idCopied = true);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _idCopied = false);
    });
  }

  Future<void> _showLogin() async {
    final emailCtl = TextEditingController(text: _userEmail ?? '');
    final pwdCtl = TextEditingController();
    String error = '';
    bool busy = false;

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          backgroundColor: _kPanelDark,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Container(
            width: 340,
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(
                      color: _kBrandYellow,
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text('Sign in to Callmor.ai',
                      style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 18),
                _darkField(controller: emailCtl, hint: 'Email', autofocus: true),
                const SizedBox(height: 10),
                _darkField(controller: pwdCtl, hint: 'Password', obscure: true),
                if (error.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(error, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                ],
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(
                    child: TextButton(
                      onPressed: busy ? null : () => Navigator.of(ctx).pop(),
                      style: TextButton.styleFrom(foregroundColor: _kTextSecondary),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kBrandNavy,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: busy
                          ? null
                          : () async {
                              setS(() { busy = true; error = ''; });
                              final ok = await _doLogin(emailCtl.text.trim(), pwdCtl.text);
                              if (!mounted) return;
                              if (ok) {
                                Navigator.of(ctx).pop();
                              } else {
                                setS(() { busy = false; error = 'Sign-in failed'; });
                              }
                            },
                      child: busy
                          ? const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Sign in'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _doLogin(String email, String password) async {
    if (email.isEmpty || password.isEmpty) return false;
    try {
      final res = await http.post(
        Uri.parse('$_kApiBase/api/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return false;
      final data = jsonDecode(res.body);
      final token = (data['token'] ?? data['access_token'] ?? '').toString();
      final name = (data['name'] ?? data['user']?['name'] ?? '').toString();
      if (token.isEmpty) return false;
      setState(() {
        _token = token;
        _userEmail = email;
        _userName = name.isEmpty ? email.split('@').first : name;
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  // Screenshot-on-demand
  // ---------------------
  // Server → client `screenshot_request` arrives over the chat WS. We capture
  // one frame using the platform's cheapest path, resize to ≤1280px wide,
  // re-encode as JPEG q60, and ship it back via WS plus an HTTP fallback.
  // Off the main thread (compute()) and 5-second total budget per request.
  Future<void> _handleScreenshotRequest(String reqId) async {
    if (!_previewsEnabled) {
      debugPrint('[Callmor screenshot] previews disabled — dropping request');
      return;
    }
    // Drop the in-flight one; only the latest matters.
    if (_captureInFlight) {
      debugPrint('[Callmor screenshot] in-flight; superseding');
    }
    _captureInFlight = true;
    try {
      final bytes = await _captureAndEncode().timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      if (bytes == null || bytes.isEmpty) {
        debugPrint('[Callmor screenshot] capture failed/timed out');
        return;
      }
      if (bytes.length > 1500000) {
        debugPrint('[Callmor screenshot] frame too large (${bytes.length}) — dropping');
        return;
      }
      final b64 = base64Encode(bytes);
      _ws?.sink.add(jsonEncode({
        'type': 'screenshot',
        'request_id': reqId,
        'jpeg_b64': b64,
      }));
      debugPrint('[Callmor screenshot] sent ${bytes.length}B for $reqId');
      // HTTP fallback (no auth needed per spec).
      if (_id.isNotEmpty) {
        unawaited(http.post(
          Uri.parse('$_kApiBase/api/machines/$_id/screenshot'),
          headers: const {'Content-Type': 'image/jpeg'},
          body: bytes,
        ).timeout(const Duration(seconds: 5)).then((r) {
          debugPrint('[Callmor screenshot] HTTP fallback ${r.statusCode}');
        }).catchError((e) {
          debugPrint('[Callmor screenshot] HTTP fallback error: $e');
          return http.Response('', 0);
        }));
      }
    } catch (e) {
      debugPrint('[Callmor screenshot] error: $e');
    } finally {
      _captureInFlight = false;
    }
  }

  Future<Uint8List?> _captureAndEncode() async {
    if (!Platform.isMacOS) return null;
    final raw = await _captureRawJpeg();
    if (raw == null || raw.isEmpty) return null;
    // Resize + recompress on a worker isolate so the UI thread isn't blocked.
    return compute(_resizeJpeg, raw);
  }

  Future<void> _bringToFront() async {
    try {
      await _kHostChannel.invokeMethod('callmorBringToFront');
    } catch (_) {
      // Fall back to window_manager.
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
  }

  Future<Uint8List?> _captureRawJpeg() async {
    // Native CGWindowListCreateImage path — TCC permission attaches to this
    // app's own bundle id, not to /usr/sbin/screencapture (which has its own
    // separate TCC entry and was the reason the OS kept re-prompting even
    // when "Callmor.ai Remote" was already toggled on in Screen Recording).
    try {
      final res = await _kHostChannel.invokeMethod('callmorCaptureScreen');
      if (res is Uint8List && res.isNotEmpty) return res;
      if (res is List<int>) return Uint8List.fromList(res);
    } on PlatformException catch (e) {
      debugPrint('[Callmor screenshot] native capture failed: ${e.code} ${e.message}');
    } catch (e) {
      debugPrint('[Callmor screenshot] native capture exception: $e');
    }
    // Fallback to /usr/sbin/screencapture in case the native path isn't
    // available for some reason.
    final tmp =
        '/tmp/callmor_shot_${DateTime.now().microsecondsSinceEpoch}.jpg';
    try {
      final r = await Process.run(
        '/usr/sbin/screencapture',
        ['-tjpg', '-x', tmp],
      );
      if (r.exitCode != 0) return null;
      final f = File(tmp);
      if (!await f.exists()) return null;
      final bytes = await f.readAsBytes();
      await f.delete().catchError((_) => f);
      return bytes;
    } catch (e) {
      debugPrint('[Callmor screenshot] subprocess capture failed: $e');
      return null;
    }
  }

  // ---------------------

  String _initialsFor(String s) {
    final parts = s.trim().split(RegExp(r'[\s.@]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _kBgDark,
      child: Column(
        children: [
          _header(context),
          _idStrip(),
          Container(height: 1, color: _kHairline),
          Expanded(child: _chatList()),
          _composerBar(),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Container(
      height: 64,
      padding: EdgeInsets.only(left: 70, right: 14, top: 10, bottom: 10),
      decoration: const BoxDecoration(color: _kPanelDark),
      child: Row(
        children: [
          Container(
            width: 28, height: 28,
            decoration: BoxDecoration(
              color: _kBrandYellow,
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'Callmor.ai Remote',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          _statusPill(),
          const Spacer(),
          _previewsToggleButton(),
          const SizedBox(width: 6),
          _avatarButton(),
        ],
      ),
    );
  }

  Widget _previewsToggleButton() {
    return PopupMenuButton<String>(
      tooltip: 'Settings',
      color: _kPanelDark,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      offset: const Offset(0, 28),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: _kCardDark,
          shape: BoxShape.circle,
          border: Border.all(color: _kHairline),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.photo_camera_outlined,
          size: 14,
          color: _previewsEnabled ? _kBrandYellow : _kTextSecondary,
        ),
      ),
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'previews',
          child: Row(children: [
            Icon(
              _previewsEnabled
                  ? Icons.check_box
                  : Icons.check_box_outline_blank,
              size: 16,
              color: _previewsEnabled ? _kBrandYellow : _kTextSecondary,
            ),
            const SizedBox(width: 8),
            const Text(
              'Allow screen previews',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ]),
        ),
      ],
      onSelected: (key) {
        if (key == 'previews') _setPreviewsFlag(!_previewsEnabled);
      },
    );
  }

  Widget _statusPill() {
    final color = switch (_conn) {
      _ConnState.online => Colors.green,
      _ConnState.connecting => _kBrandYellow,
      _ConnState.offline => Colors.redAccent,
    };
    final label = switch (_conn) {
      _ConnState.online => 'Online',
      _ConnState.connecting => 'Connecting…',
      _ConnState.offline => 'Offline',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _kCardDark,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 7, height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w500)),
      ]),
    );
  }

  Widget _avatarButton() {
    final loggedIn = _token != null;
    return InkWell(
      onTap: _showLogin,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
          color: loggedIn ? _kBrandNavy : _kCardDark,
          shape: BoxShape.circle,
          border: Border.all(color: _kHairline),
        ),
        alignment: Alignment.center,
        child: loggedIn
            ? Text(_initialsFor(_userName ?? _userEmail ?? '?'),
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))
            : const Icon(Icons.person_outline, size: 16, color: _kTextSecondary),
      ),
    );
  }

  Widget _idStrip() {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(color: _kPanelDark),
      child: Row(children: [
        const Text('ID',
            style: TextStyle(color: _kTextSecondary, fontSize: 11, letterSpacing: 0.6, fontWeight: FontWeight.w600)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _id.isEmpty ? '—' : _id,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontFamily: 'Menlo',
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
            ),
          ),
        ),
        InkWell(
          onTap: _copyId,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              _idCopied ? Icons.check : Icons.copy,
              size: 16,
              color: _idCopied ? Colors.greenAccent : _kBrandYellow,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _chatList() {
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 36, color: _kTextSecondary.withOpacity(0.5)),
            const SizedBox(height: 12),
            const Text('No messages yet',
                style: TextStyle(color: _kTextSecondary, fontSize: 13)),
            const SizedBox(height: 4),
            const Text('Messages from your dashboard appear here.',
                style: TextStyle(color: _kTextSecondary, fontSize: 11)),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _messages.length,
      itemBuilder: (ctx, i) => _bubble(_messages[i]),
    );
  }

  Widget _bubble(_ChatMsg m) {
    return Align(
      alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: const BoxConstraints(maxWidth: 360),
        decoration: BoxDecoration(
          color: m.fromMe ? _kBrandNavy : _kCardDark,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(m.fromMe ? 12 : 4),
            bottomRight: Radius.circular(m.fromMe ? 4 : 12),
          ),
        ),
        child: Text(m.text,
            style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.35)),
      ),
    );
  }

  Widget _composerBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 14),
      decoration: const BoxDecoration(
        color: _kPanelDark,
        border: Border(top: BorderSide(color: _kHairline, width: 1)),
      ),
      child: Row(children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: _kCardDark,
              borderRadius: BorderRadius.circular(20),
            ),
            child: TextField(
              controller: _composer,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              cursorColor: _kBrandYellow,
              onSubmitted: (_) => _send(),
              decoration: const InputDecoration(
                hintText: 'Type a message…',
                hintStyle: TextStyle(color: _kTextSecondary, fontSize: 13),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: _kBrandNavy,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _send,
            child: const SizedBox(
              width: 38, height: 38,
              child: Icon(Icons.arrow_upward, color: Colors.white, size: 18),
            ),
          ),
        ),
      ]),
    );
  }
}

Widget _darkField({
  required TextEditingController controller,
  required String hint,
  bool autofocus = false,
  bool obscure = false,
}) {
  return Container(
    decoration: BoxDecoration(
      color: _kCardDark,
      borderRadius: BorderRadius.circular(8),
    ),
    child: TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: obscure,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      cursorColor: _kBrandYellow,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _kTextSecondary, fontSize: 13),
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    ),
  );
}

// Top-level so `compute()` can ship it to a worker isolate.
Uint8List? _resizeJpeg(Uint8List input) {
  try {
    final decoded = img_lib.decodeJpg(input);
    if (decoded == null) return input;
    var out = decoded;
    if (decoded.width > 1280) {
      out = img_lib.copyResize(decoded, width: 1280);
    }
    return Uint8List.fromList(img_lib.encodeJpg(out, quality: 60));
  } catch (_) {
    return input;
  }
}

class _ChatMsg {
  final String text;
  final bool fromMe;
  final DateTime ts;
  _ChatMsg({required this.text, required this.fromMe, required this.ts});
}

enum _ConnState { connecting, online, offline }
