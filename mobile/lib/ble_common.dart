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

// iOS fallback: CoreBluetooth cannot advertise manufacturer data, but it can advertise service
// UUIDs. The same payload is packed into one: "FEED" + sessionId, the 8 code chars, then a fixed
// tail that marks it as ours (8-4-4-4-12 layout, so it is a valid 128-bit UUID).
final _beaconUuid = RegExp(r'^FEED([0-9A-F]{4})-([0-9A-F]{4})-([0-9A-F]{4})-A77E-0A77E4DA7A00$');

String encodeBeaconUuid(String sessionId, String rollingCode) {
  final c = rollingCode.toUpperCase();
  return 'FEED${sessionId.toUpperCase()}-${c.substring(0, 4)}-${c.substring(4)}-A77E-0A77E4DA7A00';
}

({String sessionId, String rollingCode})? decodeBeaconUuid(String uuid) {
  final m = _beaconUuid.firstMatch(uuid.toUpperCase());
  return m == null ? null : (sessionId: m[1]!, rollingCode: '${m[2]}${m[3]}'.toLowerCase());
}

/// Reads the beacon from whatever a scan result carries: manufacturer data (Android professor)
/// first, then the service-UUID encoding (iOS professor). Null if neither is ours.
({String sessionId, String rollingCode})? beaconFromAdvertisement({
  required Map<int, List<int>> manufacturerData,
  required Iterable<String> serviceUuids,
}) {
  final msd = manufacturerData[kBeaconManufacturerId];
  final fromMsd = msd == null ? null : decodeBeacon(msd);
  if (fromMsd != null) return fromMsd;
  for (final uuid in serviceUuids) {
    final fromUuid = decodeBeaconUuid(uuid);
    if (fromUuid != null) return fromUuid;
  }
  return null;
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
