import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'ble_common.dart';

final _bssid = RegExp(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$');

/// Lower-case colon-separated router BSSID, or null. The OS returns 02:00:00:00:00:00 (or all zeros)
/// when it refuses to reveal the access point, which carries no information.
String? normalizeBssid(String? raw) {
  final s = raw?.trim().toLowerCase();
  if (s == null || !_bssid.hasMatch(s)) return null;
  return s == '02:00:00:00:00:00' || s == '00:00:00:00:00:00' ? null : s;
}

/// Captures the device's location as telemetry the server can run forensic checks on.
/// Works on Android and iOS; foreground only.
class LocationVerifierService {
  /// A cold GNSS start indoors with no assistance data (no data connection) can take a minute, so labs
  /// can raise this: flutter build apk --dart-define=GPS_FIRST_FIX_SECONDS=90
  static const _firstFixLimit = Duration(seconds: int.fromEnvironment('GPS_FIRST_FIX_SECONDS', defaultValue: 30));
  static const _secondFixLimit = Duration(seconds: 4);
  static const _burstGap = Duration(milliseconds: 600);

  /// Two high-accuracy fixes 600 ms apart. Rooted spoofers (LSPosed/Xposed mock hiders) tend to inject
  /// static coordinates or 2D-only objects, which shows up as zero jitter and missing altitude data.
  /// If the second fix times out, metrics come from the single fix with sampleCount 1.
  ///
  /// Throws StateError with a user-readable message when location is off, denied, imprecise, or no
  /// fix arrives.
  Future<LocationTelemetry> captureVerifiedLocationBurst() async {
    await ensureReady();

    final Position first;
    try {
      first = await _fix(_firstFixLimit);
    } on TimeoutException {
      throw StateError('No GPS fix yet. Move closer to a window and try again.');
    }
    await Future<void>.delayed(_burstGap);
    Position? second;
    try {
      second = await _fix(_secondFixLimit);
    } on TimeoutException {
      second = null;
    }

    final latest = second ?? first;
    return LocationTelemetry(
      lat: latest.latitude,
      lon: latest.longitude,
      accuracy: latest.accuracy,
      altitude: latest.altitude,
      altitudeAccuracy: latest.altitudeAccuracy,
      speed: latest.speed,
      timestamp: latest.timestamp.millisecondsSinceEpoch,
      isMocked: first.isMocked || (second?.isMocked ?? false),
      sampleCount: second == null ? 1 : 2,
      jitterLatDelta: second == null ? 0.0 : (second.latitude - first.latitude).abs(),
      jitterLonDelta: second == null ? 0.0 : (second.longitude - first.longitude).abs(),
      jitterAccDelta: second == null ? 0.0 : (second.accuracy - first.accuracy).abs(),
      wifiBssid: await _wifiBssid(),
    );
  }

  /// Checks location services and permission (asking if needed). Public so a screen can ask up front,
  /// before a timed scan starts, instead of showing a permission dialog in the middle of it.
  Future<void> ensureReady() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location services are turned off. Turn them on and try again.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw StateError('Location permission denied. Allow precise location for this app in Settings.');
    }
    // iOS 14+ can grant only an approximate location (Android reports "unknown" here)
    if (await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.reduced) {
      throw StateError('Precise location is required. Switch "Precise Location" on for this app in Settings.');
    }
  }

  Future<Position> _fix(Duration limit) => Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(accuracy: LocationAccuracy.best, timeLimit: limit),
      );

  Future<String?> _wifiBssid() async {
    try {
      return normalizeBssid(await NetworkInfo().getWifiBSSID());
    } catch (_) {
      return null; // not on Wi-Fi, or the platform won't say: the hint is optional
    }
  }
}
