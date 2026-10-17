import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_common.dart';
import 'ble_professor_service.dart';
import 'ble_student_service.dart';
import 'location_verifier_service.dart';

/// Starting values for the config bar, baked in at build time:
///   `flutter build apk --dart-define=SERVER_URL=https://NAME.trycloudflare.com --dart-define=ACCESS_TOKEN=TOKEN`
/// Both stay editable on the phone and are remembered, because a quick-tunnel URL changes every time
/// cloudflared restarts. The default URL works over USB after `adb reverse tcp:3000 tcp:3000`.
const _defaultServerUrl = String.fromEnvironment('SERVER_URL', defaultValue: 'http://127.0.0.1:3000');
const _defaultAccessToken = String.fromEnvironment('ACCESS_TOKEN');
const _urlKey = 'server_url';
const _tokenKey = 'access_token';

/// This machine or this network: the places a plain-http server is normal (USB reverse, LAN).
final _localAddress = RegExp(r'^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)');
final _loopback = RegExp(r'^(localhost|127\.)');

void main() => runApp(const AttendanceApp());

// ---------------------------------------------------------------------------
// Phase 1 server client
// ---------------------------------------------------------------------------

class ApiException implements Exception {
  const ApiException(this.status, this.message, [this.body = const {}]);

  /// HTTP status, or 0 when the server could not be reached.
  final int status;
  final String message;

  /// The server's JSON error body (e.g. spoof_reasons, distance_m, allowed_radius_m).
  final Map<String, dynamic> body;

  /// The access token was missing or wrong (as opposed to the 401 for an expired rolling code).
  bool get isAuthFailure => status == 401 && message == AttendanceApi.authError;

  @override
  String toString() => message;
}

class AttendanceApi {
  AttendanceApi(String baseUrl, {this.token = ''}) : _base = parseBaseUrl(baseUrl);

  /// The server's message for a missing or wrong access token (see server.js).
  static const authError = 'missing or invalid access token';

  final Uri _base;

  /// Sent as `Authorization: Bearer TOKEN` on every call.
  final String token;
  static const _timeout = Duration(seconds: 5);

  /// Adds a scheme when there is none: http for local addresses (USB, LAN), https for anything else,
  /// so a pasted tunnel hostname never sends the access token in clear text.
  static Uri parseBaseUrl(String raw) {
    final s = raw.trim();
    if (s.contains('://')) return Uri.parse(s);
    return Uri.parse('${_localAddress.hasMatch(s) ? 'http' : 'https'}://$s');
  }

  Map<String, String> get _auth => {if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}'};

  ApiException get _unreachable => ApiException(
        0,
        'Cannot reach the server at $_base. Check that the server and the tunnel are running and the URL is '
        'current (a quick-tunnel URL changes every time cloudflared restarts).',
      );

  Future<Map<String, dynamic>> _call(String method, String path, [Map<String, Object?>? body]) async {
    final uri = _base.resolve(path);
    try {
      final request = method == 'GET'
          ? http.get(uri, headers: _auth)
          : http.post(uri, headers: {..._auth, 'Content-Type': 'application/json'}, body: jsonEncode(body ?? {}));
      final res = await request.timeout(_timeout);
      final decoded = _tryDecode(res.body);
      final data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      if (res.statusCode >= 400) {
        throw ApiException(res.statusCode, '${data['error'] ?? 'HTTP ${res.statusCode}'}', data);
      }
      return data;
    } on TimeoutException {
      throw _unreachable;
    } on http.ClientException {
      throw _unreachable;
    }
  }

  static Object? _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  /// GET /api/ping: the server is reachable and the access token was accepted.
  Future<void> ping() => _call('GET', '/api/ping');

  /// POST /api/session/start. [location] is the professor's anchor; [hallRadiusM] overrides the
  /// server's default hall radius (30 m).
  Future<({String sessionId, String secretSeed, int serverTimestamp, double hallRadiusM})> startSession({
    required LocationTelemetry location,
    double? hallRadiusM,
  }) async {
    final d = await _call('POST', '/api/session/start', {
      'location': location.toJson(),
      'hall_radius_m': ?hallRadiusM,
    });
    return (
      sessionId: d['session_id'] as String,
      secretSeed: d['secret_seed'] as String,
      serverTimestamp: (d['server_timestamp'] as num).toInt(),
      hallRadiusM: (d['hall_radius_m'] as num).toDouble(),
    );
  }

  /// POST /api/session/stop
  Future<void> stopSession(String sessionId) => _call('POST', '/api/session/stop', {'session_id': sessionId});

  /// GET /api/session/:session_id/report
  Future<AttendanceReport> getReport(String sessionId) async =>
      AttendanceReport.fromJson(await _call('GET', '/api/session/$sessionId/report'));

  /// POST /api/attendance/mark. [alreadyMarked] is true if this roll number was marked before;
  /// the distances are what the server measured against the professor's anchor.
  Future<({bool alreadyMarked, double distanceM, double allowedRadiusM})> markAttendance({
    required String sessionId,
    required String rollNo,
    required String name,
    required String rollingCode,
    required int rssi,
    required String deviceId,
    required LocationTelemetry location,
  }) async {
    final d = await _call('POST', '/api/attendance/mark', {
      'session_id': sessionId,
      'student_roll_no': rollNo,
      'student_name': name,
      'rolling_code': rollingCode,
      'rssi': rssi,
      'device_mac_address': deviceId,
      'location': location.toJson(),
    });
    return (
      alreadyMarked: d['already_marked'] == true,
      distanceM: (d['distance_m'] as num).toDouble(),
      allowedRadiusM: (d['allowed_radius_m'] as num).toDouble(),
    );
  }
}

class AttendanceRecord {
  AttendanceRecord.fromJson(Map<String, dynamic> j)
      : name = j['student_name'] as String,
        rollNo = j['student_roll_no'] as String,
        deviceId = j['device_mac_address'] as String,
        rssi = (j['rssi'] as num).toInt(),
        proxyFlagged = j['proxy_flagged'] == true,
        sharedWith = List<String>.from(j['shared_with_roll_nos'] as List),
        distanceM = (j['distance_m'] as num?)?.toDouble(),
        allowedRadiusM = (j['allowed_radius_m'] as num?)?.toDouble(),
        locationVerified = j['location_verified'] == true;

  final String name;
  final String rollNo;
  final String deviceId;
  final int rssi;
  final bool proxyFlagged;

  /// Distance from the professor's anchor and the variance-widened bound it was checked against.
  /// Null for records that have no location data.
  final double? distanceM;
  final double? allowedRadiusM;
  final bool locationVerified;

  /// Other roll numbers marked from the same phone.
  final List<String> sharedWith;
}

class AttendanceReport {
  AttendanceReport.fromJson(Map<String, dynamic> j)
      : records = [
          for (final r in j['records'] as List) AttendanceRecord.fromJson(r as Map<String, dynamic>),
        ];

  final List<AttendanceRecord> records;

  List<AttendanceRecord> get verified => [
        for (final r in records)
          if (!r.proxyFlagged) r,
      ];

  /// Sorted by phone so the students who shared one sit next to each other.
  List<AttendanceRecord> get flagged => [
        for (final r in records)
          if (r.proxyFlagged) r,
      ]..sort((a, b) {
          final byDevice = a.deviceId.compareTo(b.deviceId);
          return byDevice != 0 ? byDevice : a.rollNo.compareTo(b.rollNo);
        });
}

/// "Distance: 4.2m (Bound: 46.5m) • GPS Verified", shown to the professor per student and to the student on success.
String gpsSummary(double distanceM, double boundM) =>
    'Distance: ${distanceM.toStringAsFixed(1)}m (Bound: ${boundM.toStringAsFixed(1)}m) • GPS Verified';

String describeError(Object e) => switch (e) {
      ApiException ex when ex.isAuthFailure =>
        'The server rejected the access token. Check the Access Token field at the top.',
      ApiException() => e.body['spoof_reasons'] is List
          ? '${e.message}: ${(e.body['spoof_reasons'] as List).join(', ')}'
          : e.message,
      FormatException() => 'That server URL is not valid.',
      StateError() => e.message,
      UnsupportedError() => e.message ?? 'Not supported on this device',
      PlatformException() => e.message ?? e.code,
      _ => e.toString(),
    };

// ---------------------------------------------------------------------------
// App + home screen (configuration bar)
// ---------------------------------------------------------------------------

/// The server address and access token, shared by both screens. Edits apply to the next request and
/// are remembered across app restarts.
class ServerConfig {
  ServerConfig()
      : url = TextEditingController(text: _defaultServerUrl),
        token = TextEditingController(text: _defaultAccessToken);

  final TextEditingController url;
  final TextEditingController token;

  /// A client for the server as configured right now.
  AttendanceApi api() => AttendanceApi(url.text, token: token.text);

  /// Loads what was saved last time, then saves every edit. A saved value wins over the build-time default.
  Future<void> restoreAndRemember() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      url.text = prefs.getString(_urlKey) ?? url.text;
      token.text = prefs.getString(_tokenKey) ?? token.text;
      _remember(url, _urlKey, prefs);
      _remember(token, _tokenKey, prefs);
    } catch (_) {
      // storage unavailable: the fields still work, they just are not remembered
    }
  }

  static void _remember(TextEditingController c, String key, SharedPreferences prefs) {
    var saved = c.text;
    c.addListener(() {
      if (c.text == saved) return; // cursor moves notify too
      saved = c.text;
      prefs.setString(key, saved);
    });
  }

  void dispose() {
    url.dispose();
    token.dispose();
  }
}

/// A warning when the access token would cross a network in clear text (plain http to anything but
/// this phone itself), or null.
String? plainHttpWarning(String raw) {
  final Uri url;
  try {
    url = AttendanceApi.parseBaseUrl(raw);
  } on FormatException {
    return null;
  }
  if (url.scheme != 'http' || _loopback.hasMatch(url.host)) return null;
  return 'Plain http: the access token is sent unencrypted. Use the https tunnel URL.';
}

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Attendance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _config = ServerConfig();
  bool _professor = false;
  bool _showToken = false;
  bool _testing = false;
  ({bool ok, String message})? _connection; // result of the last "Test connection"

  /// True while the professor screen is starting or broadcasting: the role can't change then,
  /// otherwise the screen would be disposed with a live session and BLE advertisement.
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    unawaited(_config.restoreAndRemember());
  }

  @override
  void dispose() {
    _config.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _connection = null;
    });
    ({bool ok, String message}) result;
    try {
      await _config.api().ping();
      result = (ok: true, message: 'Connected: the server answered and accepted the access token.');
    } catch (e) {
      result = (ok: false, message: describeError(e));
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _connection = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BLE Attendance')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    TextField(
                      controller: _config.url,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Backend Server URL',
                        helperText: 'Tunnel: https://<name>.trycloudflare.com   USB: http://127.0.0.1:3000',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    ListenableBuilder(
                      listenable: _config.url,
                      builder: (context, _) {
                        final warning = plainHttpWarning(_config.url.text);
                        return warning == null
                            ? const SizedBox.shrink()
                            : Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(warning, style: TextStyle(fontSize: 12, color: Colors.orange.shade900)),
                              );
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _config.token,
                      obscureText: !_showToken,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Access Token',
                        helperText: 'Printed by the server when it starts (ACCESS_TOKEN)',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _showToken ? 'Hide token' : 'Show token',
                          icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _showToken = !_showToken),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _testing ? null : _testConnection,
                          icon: _testing
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.wifi_tethering),
                          label: const Text('Test connection'),
                        ),
                      ),
                    ),
                    if (_connection != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              _connection!.ok ? Icons.check_circle : Icons.error_outline,
                              size: 18,
                              color: _connection!.ok ? Colors.green.shade700 : Colors.red.shade700,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _connection!.message,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: _connection!.ok ? Colors.green.shade800 : Colors.red.shade800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        _professor ? 'Professor Mode' : 'Student Mode',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        _locked
                            ? 'Stop the broadcast to switch role'
                            : _professor
                                ? 'Switch off for Student Mode'
                                : 'Switch on for Professor Mode',
                      ),
                      value: _professor,
                      onChanged: _locked ? null : (v) => setState(() => _professor = v),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_professor)
              ProfessorScreen(
                config: _config,
                onLockChanged: (locked) {
                  if (locked != _locked) setState(() => _locked = locked);
                },
              )
            else
              StudentScreen(config: _config),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared UI bits
// ---------------------------------------------------------------------------

/// A red error box (the professor screen's server and Bluetooth problems).
class _Notice extends StatelessWidget {
  const _Notice(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = Colors.red;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.shade50,
        border: Border.all(color: c.shade700, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: c.shade800, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: c.shade900)),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.color,
    required this.emptyText,
    required this.children,
  });

  final String title;
  final MaterialColor color;
  final String emptyText;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color.shade800),
                ),
              ),
              Chip(
                label: Text('${children.length}'),
                backgroundColor: color.shade100,
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        if (children.isEmpty) Text(emptyText, style: const TextStyle(color: Colors.black54)) else ...children,
      ],
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile(this.record, {this.flagged = false});
  final AttendanceRecord record;
  final bool flagged;

  @override
  Widget build(BuildContext context) {
    final color = flagged ? Colors.red : Colors.green;
    return Card(
      color: color.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.shade700, width: flagged ? 1.5 : 0.5),
      ),
      child: ListTile(
        leading: Icon(flagged ? Icons.warning_amber_rounded : Icons.check_circle, color: color.shade700),
        title: Text('${record.name}  ·  ${record.rollNo}', style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'RSSI ${record.rssi} dBm\nDevice ${record.deviceId}\n'
              '${record.locationVerified && record.distanceM != null && record.allowedRadiusM != null ? gpsSummary(record.distanceM!, record.allowedRadiusM!) : 'No GPS verification'}',
            ),
            if (flagged)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Same phone also used by roll no: ${record.sharedWith.join(', ')}',
                  style: TextStyle(color: color.shade900, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }
}

/// The professor's own fix, which the server uses as the centre of the lecture hall.
class _AnchorCard extends StatelessWidget {
  const _AnchorCard({required this.anchor, required this.hallRadiusM});
  final LocationTelemetry anchor;
  final double? hallRadiusM;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.my_location),
        title: Text(
          'Classroom Anchor  ·  ±${anchor.accuracy.toStringAsFixed(1)}m',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${anchor.lat.toStringAsFixed(6)}, ${anchor.lon.toStringAsFixed(6)}\n'
          'Hall radius ${hallRadiusM?.toStringAsFixed(0) ?? '30'}m${anchor.wifiBssid != null ? '  ·  Wi-Fi AP recorded' : ''}',
        ),
        isThreeLine: true,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Professor screen
// ---------------------------------------------------------------------------

class ProfessorScreen extends StatefulWidget {
  const ProfessorScreen({super.key, required this.config, required this.onLockChanged});

  final ServerConfig config;

  /// true while a session is starting or live (the role switch must stay put).
  final ValueChanged<bool> onLockChanged;

  @override
  State<ProfessorScreen> createState() => _ProfessorScreenState();
}

class _ProfessorScreenState extends State<ProfessorScreen> {
  static const _pollEvery = Duration(seconds: 3);

  AttendanceApi? _api;

  /// Holds the secret seed; kept here, never rendered.
  BleProfessorService? _ble;
  String? _sessionId;
  AttendanceReport? _report;
  Timer? _poll;
  int _fetchSeq = 0;
  bool _busy = false;
  String? _error; // server / network
  String? _bleError; // broadcaster
  LocationTelemetry? _anchor; // the professor's own location, sent as the session's anchor
  double? _hallRadiusM;
  String? _phase; // what a slow start is currently waiting on

  @override
  void dispose() {
    _poll?.cancel();
    final ble = _ble;
    if (ble != null) unawaited(ble.stopBroadcasting());
    super.dispose();
  }

  /// setState + tell the home screen whether the role switch must be locked.
  void _update(VoidCallback change) {
    if (!mounted) return;
    setState(change);
    widget.onLockChanged(_busy || _ble != null);
  }

  Future<void> _start() async {
    _update(() {
      _busy = true;
      _error = null;
      _bleError = null;
      _report = null;
      _sessionId = null;
      _anchor = null;
      _phase = 'Reading the classroom location (two GPS fixes)…';
    });
    AttendanceApi? api;
    String? startedId;
    try {
      api = widget.config.api();
      final anchor = await LocationVerifierService().captureVerifiedLocationBurst();
      _update(() => _phase = 'Starting the session…');
      final s = await api.startSession(location: anchor);
      startedId = s.sessionId;
      final ble = BleProfessorService(
        sessionId: s.sessionId,
        secretSeed: s.secretSeed,
        // the server checks codes against ITS clock, so follow it rather than this phone's
        clockOffset: Duration(milliseconds: s.serverTimestamp - DateTime.now().millisecondsSinceEpoch),
        onError: (e) => _update(() => _bleError = 'Broadcast problem: ${describeError(e)}. Stop and start again.'),
      );
      await ble.startBroadcasting();
      _api = api;
      _poll = Timer.periodic(_pollEvery, (_) => _refresh());
      _update(() {
        _ble = ble;
        _sessionId = s.sessionId;
        _anchor = anchor;
        _hallRadiusM = s.hallRadiusM;
      });
      unawaited(_refresh());
    } catch (e) {
      // don't leave an active session on the server that nobody is broadcasting
      if (api != null && startedId != null) {
        await api.stopSession(startedId).catchError((Object _) {});
      }
      _update(() => _error = describeError(e));
    } finally {
      _update(() {
        _busy = false;
        _phase = null;
      });
    }
  }

  Future<void> _stop() async {
    final ble = _ble;
    final api = _api;
    final id = _sessionId;
    if (ble == null || api == null || id == null) return;
    _update(() => _busy = true);
    _poll?.cancel();
    _poll = null;
    String? error;
    try {
      await ble.stopBroadcasting();
    } catch (e) {
      error = describeError(e);
    }
    try {
      await api.stopSession(id);
    } catch (e) {
      error ??= describeError(e);
    }
    _update(() {
      _ble = null;
      _error = error;
    });
    await _refresh(); // final report for the ended session
    _update(() => _busy = false);
  }

  Future<void> _refresh() async {
    final id = _sessionId;
    final api = _api;
    if (id == null || api == null) return;
    final seq = ++_fetchSeq; // a slow, older response must not overwrite a newer one
    try {
      final report = await api.getReport(id);
      if (!mounted || seq != _fetchSeq) return;
      setState(() {
        _report = report;
        _error = null;
      });
    } catch (e) {
      if (!mounted || seq != _fetchSeq) return;
      setState(() => _error = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final broadcasting = _ble != null;
    final report = _report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 72,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: broadcasting ? Colors.red.shade700 : null,
              textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            onPressed: _busy ? null : (broadcasting ? _stop : _start),
            icon: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : Icon(broadcasting ? Icons.stop_circle_outlined : Icons.sensors, size: 28),
            label: Text(broadcasting ? 'Stop Broadcast' : 'Start Attendance Broadcast'),
          ),
        ),
        if (_sessionId != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              broadcasting
                  ? 'Session $_sessionId is live. Students can mark attendance.'
                  : 'Session $_sessionId has ended.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        if (_busy && _phase != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_phase!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54)),
          ),
        if (_anchor != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: _AnchorCard(anchor: _anchor!, hallRadiusM: _hallRadiusM)),
        if (_bleError != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: _Notice(_bleError!)),
        if (_error != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: _Notice(_error!)),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _sessionId == null ? null : _refresh,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh Live Attendance & Proxy Report'),
        ),
        if (broadcasting)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Auto-refreshes every 3 seconds. Keep this screen open while broadcasting.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ),
        if (report != null) ...[
          _Section(
            title: 'Verified Present Students',
            color: Colors.green,
            emptyText: 'No verified students yet.',
            children: [for (final r in report.verified) _RecordTile(r)],
          ),
          _Section(
            title: 'Flagged Proxy Alerts',
            color: Colors.red,
            emptyText: 'No shared-phone check-ins detected.',
            children: [for (final r in report.flagged) _RecordTile(r, flagged: true)],
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Student screen: three visible steps (Bluetooth, Location, Submit)
// ---------------------------------------------------------------------------

enum _CheckState { idle, running, passed, failed }

/// What one verification step currently shows.
class _CheckStatus {
  const _CheckStatus(this.state, this.headline, [this.detail]);
  final _CheckState state;
  final String headline;
  final String? detail;
}

/// One step of the check-in: a numbered card with its own state and, optionally, its own button.
class _CheckCard extends StatelessWidget {
  const _CheckCard({
    required this.step,
    required this.title,
    required this.status,
    this.actionLabel,
    this.onAction,
  });

  final int step;
  final String title;
  final _CheckStatus status;

  /// Button under the details; disabled while [onAction] is null.
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final color = switch (status.state) {
      _CheckState.idle => Colors.blueGrey,
      _CheckState.running => Colors.indigo,
      _CheckState.passed => Colors.green,
      _CheckState.failed => Colors.red,
    };
    final Widget badge = switch (status.state) {
      _CheckState.idle => CircleAvatar(
          radius: 16,
          backgroundColor: color.shade100,
          child: Text('$step', style: TextStyle(fontWeight: FontWeight.bold, color: color.shade800)),
        ),
      _CheckState.running => SizedBox(
          width: 32,
          height: 32,
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: CircularProgressIndicator(strokeWidth: 3, color: color.shade700),
          ),
        ),
      _CheckState.passed => Icon(Icons.check_circle, color: color.shade700, size: 32),
      _CheckState.failed => Icon(Icons.cancel, color: color.shade700, size: 32),
    };

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.shade700, width: status.state == _CheckState.idle ? 0.5 : 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              badge,
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Step $step · $title',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color.shade900),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 44),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status.headline, style: TextStyle(fontWeight: FontWeight.w600, color: color.shade900)),
                if (status.detail != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(status.detail!, style: TextStyle(fontSize: 13, color: color.shade900)),
                  ),
                if (actionLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StudentScreen extends StatefulWidget {
  const StudentScreen({super.key, required this.config});

  final ServerConfig config;

  @override
  State<StudentScreen> createState() => _StudentScreenState();
}

class _StudentScreenState extends State<StudentScreen> {
  // Check results go stale quickly: the broadcast code is good for seconds, and the server accepts a
  // GPS fix for 20 s. Whichever aged while the other check was running is refreshed before submitting.
  static const _beaconMaxAge = Duration(seconds: 3);
  static const _fixMaxAge = Duration(seconds: 12);

  static const _bleIdle = _CheckStatus(
    _CheckState.idle,
    'Not checked yet',
    'Hear the professor\'s broadcast at -75 dBm or stronger.',
  );
  static const _gpsIdle = _CheckStatus(
    _CheckState.idle,
    'Not checked yet',
    'Two GPS fixes, compared with the professor\'s position.',
  );
  static const _submitIdle = _CheckStatus(
    _CheckState.idle,
    'Waiting for both checks',
    'Submits automatically once Bluetooth and Location pass.',
  );
  static const _weak = _CheckStatus(
    _CheckState.failed,
    'Signal Too Weak (Move Closer)',
    'The class broadcast was heard, but it is weaker than -75 dBm.',
  );
  static const _noBroadcast = _CheckStatus(
    _CheckState.failed,
    'No Active Class Broadcast Found',
    'Make sure the professor has started the broadcast, then try again.',
  );

  final _name = TextEditingController();
  final _roll = TextEditingController();
  final _bleService = BleStudentService();
  final _gpsService = LocationVerifierService();
  final _stepsKey = GlobalKey();

  _CheckStatus _bleCheck = _bleIdle;
  _CheckStatus _gpsCheck = _gpsIdle;
  _CheckStatus _submitCheck = _submitIdle;

  // What the two checks collected, held only until the submission uses (or discards) it.
  ProfessorBeacon? _beacon;
  LocationTelemetry? _location;
  DateTime? _locationAt;

  bool get _bleOk => _bleCheck.state == _CheckState.passed;
  bool get _gpsOk => _gpsCheck.state == _CheckState.passed;
  bool get _submitting => _submitCheck.state == _CheckState.running;
  bool get _anyRunning =>
      _bleCheck.state == _CheckState.running || _gpsCheck.state == _CheckState.running || _submitting;

  @override
  void dispose() {
    _name.dispose();
    _roll.dispose();
    super.dispose();
  }

  void _set({_CheckStatus? ble, _CheckStatus? gps, _CheckStatus? submit}) {
    if (!mounted) return;
    setState(() {
      if (ble != null) _bleCheck = ble;
      if (gps != null) _gpsCheck = gps;
      if (submit != null) _submitCheck = submit;
    });
  }

  /// Scrolls the three step cards to the top of the screen so all of them are in view while a check runs.
  void _showSteps() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final steps = _stepsKey.currentContext;
      if (steps != null && steps.mounted) {
        Scrollable.ensureVisible(steps, duration: const Duration(milliseconds: 300), alignment: 0.0);
      }
    });
  }

  bool _identityOk() {
    if (_name.text.trim().isNotEmpty && _roll.text.trim().isNotEmpty) return true;
    _set(
      submit: const _CheckStatus(
        _CheckState.failed,
        'Enter your name and roll number',
        'Attendance needs both before it can be submitted.',
      ),
    );
    return false;
  }

  /// A finished submission means the next check starts a new attempt: forget the old one.
  void _resetIfDone() {
    if (_submitCheck.state != _CheckState.passed) return;
    _beacon = null;
    _location = null;
    _set(ble: _bleIdle, gps: _gpsIdle, submit: _submitIdle);
  }

  /// Runs both checks side by side, after asking for every permission up front so no dialog opens
  /// in the middle of the timed scan. Submits by itself once both pass.
  Future<void> _verifyBoth() async {
    if (!_identityOk()) return;
    FocusScope.of(context).unfocus();
    _beacon = null;
    _location = null;
    const getting = _CheckStatus(_CheckState.running, 'Getting ready…');
    _set(ble: getting, gps: getting, submit: _submitIdle);
    _showSteps();

    String? bleBlock;
    String? gpsBlock;
    try {
      if (!await requestBlePermissions(advertise: false)) bleBlock = 'Bluetooth permission denied.';
    } catch (e) {
      bleBlock = describeError(e);
    }
    try {
      await _gpsService.ensureReady();
    } catch (e) {
      gpsBlock = describeError(e);
    }

    final runs = <Future<void>>[];
    if (bleBlock != null) {
      _set(ble: _CheckStatus(_CheckState.failed, 'Bluetooth unavailable', bleBlock));
    } else {
      runs.add(_verifyBluetooth());
    }
    if (gpsBlock != null) {
      _set(gps: _CheckStatus(_CheckState.failed, 'Location unavailable', gpsBlock));
    } else {
      runs.add(_verifyLocation());
    }
    await Future.wait(runs);
  }

  /// Step 1: the professor's broadcast must be heard at -75 dBm or stronger.
  Future<void> _verifyBluetooth() async {
    _resetIfDone();
    _showSteps();
    _set(
      ble: const _CheckStatus(
        _CheckState.running,
        'Scanning for the class broadcast…',
        'Hold this phone near the professor\'s phone (up to 6 seconds).',
      ),
    );
    try {
      final beacon = await _bleService.scanForSession();
      if (beacon == null) {
        _set(ble: _bleService.heardTooWeak ? _weak : _noBroadcast);
        return;
      }
      _beacon = beacon;
      _set(
        ble: _CheckStatus(
          _CheckState.passed,
          'Class broadcast heard',
          'Session ${beacon.sessionId} at ${beacon.rssi} dBm (needs -75 dBm or stronger).',
        ),
      );
    } catch (e) {
      _set(ble: _CheckStatus(_CheckState.failed, 'Bluetooth check failed', describeError(e)));
      return;
    }
    await _maybeSubmit();
  }

  /// Step 2: two GPS fixes. The server compares them with the professor's position on submit.
  Future<void> _verifyLocation() async {
    _resetIfDone();
    _showSteps();
    _set(
      gps: const _CheckStatus(
        _CheckState.running,
        'Reading your location…',
        'Two high-accuracy GPS fixes. Near a window this takes a few seconds; a cold GPS start can take up to 30.',
      ),
    );
    try {
      final location = await _gpsService.captureVerifiedLocationBurst();
      if (location.isMocked) {
        _set(
          gps: const _CheckStatus(
            _CheckState.failed,
            'Mock location detected',
            'Switch off any fake-GPS app or the mock location setting in Developer options, then try again.',
          ),
        );
        return;
      }
      _location = location;
      _locationAt = DateTime.now();
      _set(
        gps: _CheckStatus(
          _CheckState.passed,
          'Location captured',
          '±${location.accuracy.toStringAsFixed(1)}m accuracy · '
              '${location.sampleCount == 2 ? 'two fixes' : 'one fix (the second timed out)'}'
              '${location.wifiBssid != null ? ' · Wi-Fi AP noted' : ''} · checked against the professor on submit',
        ),
      );
    } catch (e) {
      _set(gps: _CheckStatus(_CheckState.failed, 'Location check failed', describeError(e)));
      return;
    }
    await _maybeSubmit();
  }

  /// Step 3 fires on its own the moment both checks have passed.
  Future<void> _maybeSubmit() async {
    if (_bleOk && _gpsOk && !_submitting) await _submit();
  }

  Future<void> _submit() async {
    if (!_identityOk()) return;
    final name = _name.text.trim();
    final roll = _roll.text.trim();
    _set(
      submit: const _CheckStatus(
        _CheckState.running,
        'Submitting attendance…',
        'Sending the broadcast code, signal strength, device ID and location to the server.',
      ),
    );
    try {
      var location = _location!;
      if (DateTime.now().difference(_locationAt!) > _fixMaxAge) {
        location = await _gpsService.captureVerifiedLocationBurst();
        _location = location;
        _locationAt = DateTime.now();
      }
      var beacon = _beacon!;
      if (DateTime.now().difference(beacon.heardAt) > _beaconMaxAge) {
        beacon = await _bleService.scanForSession() ?? beacon;
        _beacon = beacon;
      }
      final marked = await widget.config.api().markAttendance(
        sessionId: beacon.sessionId,
        rollNo: roll,
        name: name,
        rollingCode: beacon.rollingCode,
        rssi: beacon.rssi,
        deviceId: await getDeviceMacOrHardwareId(),
        location: location,
      );
      _beacon = null;
      _location = null;
      _set(
        ble: _CheckStatus(
          _CheckState.passed,
          'Bluetooth verified',
          'Session ${beacon.sessionId} at ${beacon.rssi} dBm · broadcast code accepted by the server.',
        ),
        gps: _CheckStatus(_CheckState.passed, 'Location verified', gpsSummary(marked.distanceM, marked.allowedRadiusM)),
        submit: _CheckStatus(
          _CheckState.passed,
          'Attendance Marked Verified!',
          marked.alreadyMarked ? 'Roll no $roll was already marked for this class.' : '$name ($roll) is marked present.',
        ),
      );
    } on ApiException catch (e) {
      _applyRejection(e);
    } catch (e) {
      _set(submit: _CheckStatus(_CheckState.failed, 'Could not submit', describeError(e)));
    }
  }

  /// The server's verdict, put on the card of the check that caused it. The other check keeps its
  /// result, so fixing the failed one is enough: attendance then submits again by itself.
  void _applyRejection(ApiException e) {
    final msg = e.message;
    _CheckStatus notSubmitted(String check) => _CheckStatus(
          _CheckState.failed,
          'Not submitted',
          'The server rejected the $check check. Fix it and attendance submits automatically.',
        );

    if (e.isAuthFailure) {
      // not an expired rolling code (also a 401): the access token in the top bar is wrong
      _set(submit: _CheckStatus(_CheckState.failed, 'Access token rejected', describeError(e)));
    } else if (e.status == 403 && msg.contains('weak')) {
      _beacon = null;
      _set(ble: _weak, submit: notSubmitted('Bluetooth'));
    } else if (e.status == 403 && msg.startsWith('Location authenticity')) {
      final reasons = e.body['spoof_reasons'];
      _location = null;
      _set(
        gps: _CheckStatus(
          _CheckState.failed,
          'Location Check Failed',
          'Rejected because: ${reasons is List ? reasons.join(', ') : 'unknown reason'}',
        ),
        submit: notSubmitted('Location'),
      );
    } else if (e.status == 403 && msg.startsWith('Outside lecture hall')) {
      final d = (e.body['distance_m'] as num?)?.toStringAsFixed(1);
      final bound = (e.body['allowed_radius_m'] as num?)?.toStringAsFixed(1);
      _location = null;
      _set(
        gps: _CheckStatus(
          _CheckState.failed,
          'Outside Lecture Hall Boundary',
          'You are ${d ?? '?'}m from the professor; the allowed radius is ${bound ?? '?'}m.',
        ),
        submit: notSubmitted('Location'),
      );
    } else if ((e.status == 403 && msg.contains('not active')) || e.status == 404) {
      _beacon = null;
      _set(ble: _CheckStatus(_CheckState.failed, 'No Active Class Broadcast Found', msg), submit: notSubmitted('Bluetooth'));
    } else if (e.status == 401) {
      _beacon = null;
      _set(
        ble: const _CheckStatus(
          _CheckState.failed,
          'Broadcast code expired',
          'The code changed before it reached the server. Verify Bluetooth again.',
        ),
        submit: notSubmitted('Bluetooth'),
      );
    } else {
      _set(submit: _CheckStatus(_CheckState.failed, 'Could not submit', msg));
    }
  }

  /// Button text for a check's own action: Verify, Re-check or Retry.
  String _actionLabel(_CheckStatus s, String what) => switch (s.state) {
        _CheckState.idle => 'Verify $what',
        _CheckState.running => 'Checking…',
        _CheckState.passed => 'Re-check $what',
        _CheckState.failed => 'Retry $what',
      };

  @override
  Widget build(BuildContext context) {
    final canRetrySubmit = _submitCheck.state == _CheckState.failed && _bleOk && _gpsOk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Student Name',
            prefixIcon: Icon(Icons.person),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _roll,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Student Roll Number',
            prefixIcon: Icon(Icons.badge),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 64,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            onPressed: _anyRunning ? null : _verifyBoth,
            icon: const Icon(Icons.verified_user, size: 28),
            label: const Text('Verify Both & Mark Attendance'),
          ),
        ),
        Column(
          key: _stepsKey,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CheckCard(
              step: 1,
              title: 'Bluetooth proximity',
              status: _bleCheck,
              actionLabel: _actionLabel(_bleCheck, 'Bluetooth'),
              onAction: _bleCheck.state == _CheckState.running || _submitting ? null : _verifyBluetooth,
            ),
            _CheckCard(
              step: 2,
              title: 'Location',
              status: _gpsCheck,
              actionLabel: _actionLabel(_gpsCheck, 'Location'),
              onAction: _gpsCheck.state == _CheckState.running || _submitting ? null : _verifyLocation,
            ),
            _CheckCard(
              step: 3,
              title: 'Attendance submission',
              status: _submitCheck,
              actionLabel: canRetrySubmit ? 'Retry submit' : null,
              onAction: canRetrySubmit ? _submit : null,
            ),
          ],
        ),
      ],
    );
  }
}
