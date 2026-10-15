import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// 16-bit 0xFEED on the Bluetooth Base UUID, so Android puts it on air as 2 bytes.
/// Scanners filter on it; the "SESSION:code" payload rides in manufacturer data.
/// (13 payload bytes + headers = 21 bytes, well inside the 31-byte legacy advert.)
const kBeaconServiceUuid = '0000FEED-0000-1000-8000-00805F9B34FB';

/// 0xFFFF is the Bluetooth SIG's reserved "internal / testing" company id.
const kBeaconManufacturerId = 0xFFFF;

/// Weaker than this = outside the classroom (same cut-off the server enforces).
const kMinRssi = -75;

Uint8List encodeBeacon(String sessionId, String rollingCode) =>
    Uint8List.fromList(utf8.encode('$sessionId:$rollingCode'));

final _beacon = RegExp(r'^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{8})$');

/// Parses "4A9F:1a2b3c4d". Returns null for anything that is not ours
/// (other devices on the same UUID, truncated or garbled packets).
({String sessionId, String rollingCode})? decodeBeacon(List<int> bytes) {
  final m = _beacon.firstMatch(utf8.decode(bytes, allowMalformed: true));
  return m == null ? null : (sessionId: m[1]!.toUpperCase(), rollingCode: m[2]!.toLowerCase());
}

/// Foreground-only runtime permissions. Returns false if the user refused any.
/// Android 12+ needs the new Bluetooth permissions; Android 11 and below needs
/// location to scan; iOS needs Bluetooth.
Future<bool> requestBlePermissions({required bool advertise}) async {
  final List<Permission> needed;
  if (Platform.isAndroid) {
    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    needed = sdk >= 31
        ? [advertise ? Permission.bluetoothAdvertise : Permission.bluetoothScan, Permission.bluetoothConnect]
        : [if (!advertise) Permission.locationWhenInUse];
  } else {
    needed = [Permission.bluetooth];
  }
  if (needed.isEmpty) return true;
  return (await needed.request()).values.every((s) => s.isGranted);
}
