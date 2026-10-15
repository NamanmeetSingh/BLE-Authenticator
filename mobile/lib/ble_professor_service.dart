import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';

import 'ble_common.dart';
import 'totp_helper.dart';

/// Professor side: advertises "$sessionId:$rollingCode" and swaps in a fresh code every 5 s.
/// Android only: iOS cannot put manufacturer data in an advertisement, so the payload cannot be sent.
class BleProfessorService {
  BleProfessorService({
    required this.sessionId,
    required this.secretSeed,
    this.clockOffset = Duration.zero,
    this.onError,
  }) {
    if (!RegExp(r'^[0-9A-Fa-f]{4}$').hasMatch(sessionId)) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must be 4 hex characters');
    }
  }

  final String sessionId;
  final String secretSeed;

  /// Server clock minus this phone's clock (from the start response's server_timestamp).
  /// The server checks codes against ITS clock, so following it removes phone clock drift
  /// as a failure mode.
  final Duration clockOffset;

  /// Called when a background refresh fails (e.g. Bluetooth switched off mid-class).
  /// If null, the error is rethrown into the zone so it is not lost.
  final void Function(Object error)? onError;

  static const _step = Duration(seconds: 5);

  final _ble = FlutterBlePeripheral();
  Timer? _timer;
  bool _running = false;
  bool _busy = false;

  Future<void> startBroadcasting() async {
    if (_running) return;
    if (!Platform.isAndroid) {
      throw UnsupportedError('Broadcasting needs an Android phone: iOS cannot advertise manufacturer data.');
    }
    if (!await requestBlePermissions(advertise: true)) {
      throw StateError('Bluetooth permission denied');
    }

    _running = true;
    try {
      await _advertise();
    } catch (_) {
      _running = false;
      rethrow;
    }

    // Start the 5 s timer on the epoch grid the server counts in, so every broadcast
    // code is "current" for its whole 5 s life and students keep a full extra step
    // (the server accepts +/-1) to post it after reading it.
    final toBoundary = _step.inMilliseconds - _now().millisecondsSinceEpoch % _step.inMilliseconds;
    _timer = Timer(Duration(milliseconds: toBoundary), () {
      _tick();
      _timer = Timer.periodic(_step, (_) => _tick());
    });
  }

  Future<void> stopBroadcasting() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    await _ble.stop();
  }

  DateTime _now() => DateTime.now().add(clockOffset);

  void _tick() => unawaited(_advertise().catchError((Object e, StackTrace s) {
        final handler = onError;
        if (handler == null) Error.throwWithStackTrace(e, s);
        handler(e);
      }));

  Future<void> _advertise() async {
    if (_busy) return; // a slow restart must not overlap the next tick
    _busy = true;
    try {
      // Android cannot update a live advertisement in place: stop, then start with the new code.
      await _ble.stop();
      if (!_running) return;

      final rollingCode = generateRollingCode(secretSeed, now: _now()); // in memory only
      final state = await _ble.start(
        advertiseData: AndroidAdvertiseData(
          serviceUuid: kBeaconServiceUuid,
          manufacturerId: kBeaconManufacturerId,
          manufacturerData: encodeBeacon(sessionId, rollingCode),
        ),
        // non-connectable, low-latency, high TX power: the plugin defaults, spelled out
        androidSettings: const AndroidAdvertiseSettings(advertiseSettings: AdvertiseSettings()),
      );
      if (state != PeripheralBluetoothState.ready) {
        throw StateError('Advertising did not start: ${state.name}');
      }
    } finally {
      _busy = false;
    }
  }
}
