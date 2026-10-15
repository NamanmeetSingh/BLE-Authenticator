import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:android_id/android_id.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_common.dart';

/// What the student phone heard from the professor phone.
/// [rollingCode] goes straight into the attendance request; it must never be shown.
class ProfessorBeacon {
  const ProfessorBeacon({required this.sessionId, required this.rollingCode, required this.rssi});

  final String sessionId;
  final String rollingCode;
  final int rssi;

  /// Leaves the code out so it cannot leak into a Text(), a log line or a crash report.
  @override
  String toString() => 'ProfessorBeacon(sessionId: $sessionId, rssi: $rssi)';
}

/// Student side. Foreground only: call [scanForSession] from a button press.
class BleStudentService {
  static const scanWindow = Duration(seconds: 6);

  /// Scans for up to 6 s and returns the first in-range professor beacon, or null if none was
  /// heard. Stops scanning as soon as one is found so the code is as fresh as possible.
  /// Throws StateError if permission is denied or Bluetooth is off.
  ///
  /// ponytail: first in-range beacon wins. If neighbouring classrooms overlap, collect the whole
  /// window and take the strongest RSSI instead.
  Future<ProfessorBeacon?> scanForSession() async {
    if (!await requestBlePermissions(advertise: false)) {
      throw StateError('Bluetooth permission denied');
    }
    try {
      // waits through iOS's brief "unknown" state; times out when Bluetooth is really off
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 3));
    } on TimeoutException {
      throw StateError('Bluetooth is turned off');
    }

    final found = Completer<ProfessorBeacon?>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final beacon = _toBeacon(r);
        if (beacon != null && !found.isCompleted) found.complete(beacon);
      }
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(kBeaconServiceUuid)],
        timeout: scanWindow,
        continuousUpdates: true, // re-read RSSI and payload on every advert, not just the first
      );
      return await found.future.timeout(scanWindow, onTimeout: () => null);
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  ProfessorBeacon? _toBeacon(ScanResult r) {
    if (r.rssi < kMinRssi) return null; // too far away
    final bytes = r.advertisementData.manufacturerData[kBeaconManufacturerId];
    if (bytes == null) return null;
    final payload = decodeBeacon(bytes);
    if (payload == null) return null;
    return ProfessorBeacon(sessionId: payload.sessionId, rollingCode: payload.rollingCode, rssi: r.rssi);
  }
}

/// Formats [raw] as a MAC-looking id ("02:A1:...") by hashing it, so the raw OS identifier never
/// leaves the phone. The locally-administered bit is set so it can't be mistaken for a real MAC.
String macStyleId(String raw) {
  final h = sha256.convert(utf8.encode(raw)).bytes;
  final b = [(h[0] & 0xFE) | 0x02, h[1], h[2], h[3], h[4], h[5]];
  return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(':').toUpperCase();
}

/// Stable per-phone identifier, sent as `device_mac_address` to the server.
///
/// Neither OS lets an app read the phone's real MAC (Android returns 02:00:00:00:00:00, iOS has
/// none), and Wi-Fi BSSID/IP belong to the network, so they would change from room to room.
/// Instead:
///  - Android: ANDROID_ID, which survives logout, account switching and reinstall.
///    (device_info_plus's `androidInfo.id` is Build.ID, a firmware label shared by every phone of
///    the same model and build, so it would flag unrelated students as sharing a phone.)
///  - iOS: identifierForVendor, which survives logout and account switching, and resets only if
///    every app from this vendor is uninstalled.
Future<String> getDeviceMacOrHardwareId() async {
  final String? raw;
  if (Platform.isAndroid) {
    raw = await const AndroidId().getId();
  } else if (Platform.isIOS) {
    raw = (await DeviceInfoPlugin().iosInfo).identifierForVendor;
  } else {
    throw UnsupportedError('Only Android and iOS are supported');
  }
  if (raw == null || raw.isEmpty) {
    // refuse rather than fall back to something shared between phones
    throw StateError('The OS did not provide a device identifier');
  }
  return macStyleId(raw);
}
