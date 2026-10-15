import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' as http;

import 'ble_professor_service.dart';
import 'ble_student_service.dart';

/// Reachable from a USB-connected phone after `adb reverse tcp:3000 tcp:3000`.
const _defaultServerUrl = 'http://127.0.0.1:3000';

void main() => runApp(const AttendanceApp());

// ---------------------------------------------------------------------------
// Phase 1 server client
// ---------------------------------------------------------------------------

class ApiException implements Exception {
  const ApiException(this.status, this.message);

  /// HTTP status, or 0 when the server could not be reached.
  final int status;
  final String message;

  @override
  String toString() => message;
}

class AttendanceApi {
  AttendanceApi(String baseUrl) : _base = _parse(baseUrl);

  final Uri _base;
  static const _timeout = Duration(seconds: 5);

  static Uri _parse(String raw) {
    final s = raw.trim();
    return Uri.parse(s.contains('://') ? s : 'http://$s');
  }

  ApiException get _unreachable => ApiException(
        0,
        'Cannot reach the server at $_base. Check that it is running and the URL is right '
        '(USB phones need "adb reverse tcp:3000 tcp:3000").',
      );

  Future<Map<String, dynamic>> _call(String method, String path, [Map<String, Object?>? body]) async {
    final uri = _base.resolve(path);
    try {
      final request = method == 'GET'
          ? http.get(uri)
          : http.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body ?? {}));
      final res = await request.timeout(_timeout);
      final decoded = _tryDecode(res.body);
      final data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      if (res.statusCode >= 400) {
        throw ApiException(res.statusCode, '${data['error'] ?? 'HTTP ${res.statusCode}'}');
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

  /// POST /api/session/start
  Future<({String sessionId, String secretSeed, int serverTimestamp})> startSession() async {
    final d = await _call('POST', '/api/session/start');
    return (
      sessionId: d['session_id'] as String,
      secretSeed: d['secret_seed'] as String,
      serverTimestamp: (d['server_timestamp'] as num).toInt(),
    );
  }

  /// POST /api/session/stop
  Future<void> stopSession(String sessionId) => _call('POST', '/api/session/stop', {'session_id': sessionId});

  /// GET /api/session/:session_id/report
  Future<AttendanceReport> getReport(String sessionId) async =>
      AttendanceReport.fromJson(await _call('GET', '/api/session/$sessionId/report'));

  /// POST /api/attendance/mark. Returns true if this roll number was already marked.
  Future<bool> markAttendance({
    required String sessionId,
    required String rollNo,
    required String name,
    required String rollingCode,
    required int rssi,
    required String deviceId,
  }) async {
    final d = await _call('POST', '/api/attendance/mark', {
      'session_id': sessionId,
      'student_roll_no': rollNo,
      'student_name': name,
      'rolling_code': rollingCode,
      'rssi': rssi,
      'device_mac_address': deviceId,
    });
    return d['already_marked'] == true;
  }
}

class AttendanceRecord {
  AttendanceRecord.fromJson(Map<String, dynamic> j)
      : name = j['student_name'] as String,
        rollNo = j['student_roll_no'] as String,
        deviceId = j['device_mac_address'] as String,
        rssi = (j['rssi'] as num).toInt(),
        proxyFlagged = j['proxy_flagged'] == true,
        sharedWith = List<String>.from(j['shared_with_roll_nos'] as List);

  final String name;
  final String rollNo;
  final String deviceId;
  final int rssi;
  final bool proxyFlagged;

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

String describeError(Object e) => switch (e) {
      ApiException() => e.message,
      StateError() => e.message,
      UnsupportedError() => e.message ?? 'Not supported on this device',
      PlatformException() => e.message ?? e.code,
      _ => e.toString(),
    };

// ---------------------------------------------------------------------------
// App + home screen (configuration bar)
// ---------------------------------------------------------------------------

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
  final _serverUrl = TextEditingController(text: _defaultServerUrl);
  bool _professor = false;

  /// True while the professor screen is starting or broadcasting: the role can't change then,
  /// otherwise the screen would be disposed with a live session and BLE advertisement.
  bool _locked = false;

  @override
  void dispose() {
    _serverUrl.dispose();
    super.dispose();
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
                      controller: _serverUrl,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Backend Server URL',
                        helperText: 'USB: http://127.0.0.1:3000 (adb reverse)   Wi-Fi: http://192.168.1.X:3000',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
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
                serverUrl: _serverUrl,
                onLockChanged: (locked) {
                  if (locked != _locked) setState(() => _locked = locked);
                },
              )
            else
              StudentScreen(serverUrl: _serverUrl),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared UI bits
// ---------------------------------------------------------------------------

enum _Tone {
  success(Colors.green, Icons.check_circle),
  warning(Colors.orange, Icons.warning_amber_rounded),
  error(Colors.red, Icons.error_outline),
  info(Colors.blueGrey, Icons.bluetooth_searching);

  const _Tone(this.color, this.icon);
  final MaterialColor color;
  final IconData icon;
}

class _Status {
  const _Status(this.tone, this.title, [this.detail]);
  final _Tone tone;
  final String title;
  final String? detail;
}

class _Notice extends StatelessWidget {
  const _Notice(this.status);
  final _Status status;

  @override
  Widget build(BuildContext context) {
    final c = status.tone.color;
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
          Icon(status.tone.icon, color: c.shade800, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.title,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: c.shade900),
                ),
                if (status.detail != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(status.detail!, style: TextStyle(color: c.shade900)),
                  ),
              ],
            ),
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
            Text('RSSI ${record.rssi} dBm\nDevice ${record.deviceId}'),
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

// ---------------------------------------------------------------------------
// Professor screen
// ---------------------------------------------------------------------------

class ProfessorScreen extends StatefulWidget {
  const ProfessorScreen({super.key, required this.serverUrl, required this.onLockChanged});

  final TextEditingController serverUrl;

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
    });
    AttendanceApi? api;
    String? startedId;
    try {
      api = AttendanceApi(widget.serverUrl.text);
      final s = await api.startSession();
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
      });
      unawaited(_refresh());
    } catch (e) {
      // don't leave an active session on the server that nobody is broadcasting
      if (api != null && startedId != null) {
        await api.stopSession(startedId).catchError((Object _) {});
      }
      _update(() => _error = describeError(e));
    } finally {
      _update(() => _busy = false);
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
        if (_bleError != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: _Notice(_Status(_Tone.error, _bleError!))),
        if (_error != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: _Notice(_Status(_Tone.error, _error!))),
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
// Student screen
// ---------------------------------------------------------------------------

class StudentScreen extends StatefulWidget {
  const StudentScreen({super.key, required this.serverUrl});

  final TextEditingController serverUrl;

  @override
  State<StudentScreen> createState() => _StudentScreenState();
}

class _StudentScreenState extends State<StudentScreen> {
  static const _weak = _Status(
    _Tone.warning,
    'Signal Too Weak (Move Closer)',
    'The class broadcast was heard, but it is weaker than -75 dBm.',
  );
  static const _noBroadcast = _Status(
    _Tone.error,
    'No Active Class Broadcast Found',
    'Make sure the professor has started the broadcast, then try again.',
  );

  final _name = TextEditingController();
  final _roll = TextEditingController();
  final _ble = BleStudentService();
  _Status? _status;
  bool _scanning = false;

  @override
  void dispose() {
    _name.dispose();
    _roll.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final name = _name.text.trim();
    final roll = _roll.text.trim();
    if (name.isEmpty || roll.isEmpty) {
      setState(() => _status = const _Status(_Tone.error, 'Enter your name and roll number first'));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _scanning = true;
      _status = const _Status(
        _Tone.info,
        'Scanning for the class broadcast…',
        'Keep this phone near the professor\'s phone (up to 6 seconds).',
      );
    });

    _Status result;
    try {
      // Read the device id first, so the request follows the scan immediately:
      // the broadcast code is only good for a few seconds.
      final deviceId = await getDeviceMacOrHardwareId();
      final beacon = await _ble.scanForSession(); // asks for BLE permissions, rejects rssi < -75
      if (beacon == null) {
        result = _ble.heardTooWeak ? _weak : _noBroadcast;
      } else {
        final already = await AttendanceApi(widget.serverUrl.text).markAttendance(
          sessionId: beacon.sessionId,
          rollNo: roll,
          name: name,
          rollingCode: beacon.rollingCode,
          rssi: beacon.rssi,
          deviceId: deviceId,
        );
        result = _Status(
          _Tone.success,
          'Attendance Marked Verified!',
          already ? 'Roll no $roll was already marked for this class.' : '$name ($roll) is marked present.',
        );
      }
    } on ApiException catch (e) {
      result = _fromApi(e);
    } catch (e) {
      result = _Status(_Tone.error, describeError(e));
    }
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _status = result;
    });
  }

  _Status _fromApi(ApiException e) {
    if (e.status == 403 && e.message.contains('weak')) return _weak;
    if (e.status == 403 || e.status == 404) {
      return _Status(_Tone.error, 'No Active Class Broadcast Found', e.message);
    }
    if (e.status == 401) {
      return const _Status(
        _Tone.warning,
        'Code Expired, Scan Again',
        'The broadcast code changed before it reached the server.',
      );
    }
    return _Status(_Tone.error, e.message);
  }

  @override
  Widget build(BuildContext context) {
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
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : const Icon(Icons.bluetooth_searching, size: 28),
            label: Text(_scanning ? 'Scanning…' : 'Scan & Mark Attendance'),
          ),
        ),
        if (_status != null) Padding(padding: const EdgeInsets.only(top: 16), child: _Notice(_status!)),
      ],
    );
  }
}
