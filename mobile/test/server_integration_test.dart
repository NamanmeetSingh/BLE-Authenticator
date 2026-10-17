import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ble_attendance/ble_common.dart';
import 'package:ble_attendance/main.dart';
import 'package:ble_attendance/totp_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Runs the professor and student protocol, including the location verification, against a live
/// server (everything except the BLE radio and the real GPS chip). Start the server with a known token
/// (it prints one when it starts), then:
///   `ATTENDANCE_SERVER=http://127.0.0.1:3000 ATTENDANCE_TOKEN=TOKEN flutter test test/server_integration_test.dart`
void main() {
  final url = Platform.environment['ATTENDANCE_SERVER'];
  final token = Platform.environment['ATTENDANCE_TOKEN'];

  const profLat = 28.6139; // _loc() defaults to this latitude and longitude 77.2090
  const profSigma = 8.3;
  const studentSigma = 6.7;
  const hallRadius = 30.0; // the server default
  final bound = hallRadius + sqrt(profSigma * profSigma + studentSigma * studentSigma); // 40.67 m

  /// Moves [meters] due north (1 degree of latitude = R * pi / 180 on the server's sphere).
  double northOf(double lat, double meters) => lat + meters / (6371000 * pi / 180);

  group('live server', () {
    late AttendanceApi api;
    late _Session hall;

    setUpAll(() async {
      api = AttendanceApi(url!, token: token!);
      hall = await _Session.start(api, _loc(accuracy: profSigma));
    });

    tearDownAll(() async => api.stopSession(hall.id));

    test('the access token gates every /api call, before any payload is looked at', () async {
      await api.ping(); // the right token is accepted

      final base = Uri.parse(url!);
      final none = await http.get(base.resolve('/api/ping'));
      expect(none.statusCode, 401);
      expect(none.headers['www-authenticate'], 'Bearer');
      await expectLater(
        AttendanceApi(url, token: 'definitely-not-the-token').ping(),
        throwsA(isA<ApiException>().having((e) => e.isAuthFailure, 'isAuthFailure', isTrue)),
      );
      await expectLater(
        AttendanceApi(url).startSession(location: _loc()),
        throwsA(isA<ApiException>().having((e) => e.isAuthFailure, 'isAuthFailure', isTrue)),
      );

      // garbage without a token is a plain 401 (nothing about the payload is revealed); with it, a 400
      final withoutToken = await http.post(base.resolve('/api/session/start'),
          headers: {'Content-Type': 'application/json'}, body: '{not json');
      expect(withoutToken.statusCode, 401);
      final withToken = await http.post(base.resolve('/api/session/start'),
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'}, body: '{not json');
      expect(withToken.statusCode, 400);
    });

    test('protocol: start returns the seed and the default hall radius', () {
      expect(hall.id, matches(RegExp(r'^[0-9A-F]{4}$')));
      expect(hall.seed, hasLength(32));
      expect(hall.hallRadiusM, hallRadius);
    });

    test('a. check-in inside hall_radius_m + sqrt(prof_sigma^2 + student_sigma^2) is verified', () async {
      final r = await hall.mark(_loc(lat: northOf(profLat, 38), accuracy: studentSigma), roll: 'A1');
      expect(r.alreadyMarked, isFalse);
      expect(r.distanceM, closeTo(38.0, 0.05));
      expect(r.allowedRadiusM, closeTo(bound, 0.01));
    });

    test('a2. just beyond the variance bound is rejected, with the exact distances', () async {
      await expectLater(
        hall.mark(_loc(lat: northOf(profLat, 42), accuracy: studentSigma), roll: 'A2'),
        throwsA(_rejected(403, 'Outside lecture hall variance boundary').having(
          (e) => [e.body['distance_m'], e.body['allowed_radius_m']],
          'distance and bound',
          [closeTo(42.0, 0.05), closeTo(bound, 0.01)],
        )),
      );
    });

    test('b. 150 m away is rejected', () async {
      await expectLater(
        hall.mark(_loc(lat: northOf(profLat, 150), accuracy: studentSigma), roll: 'B1'),
        throwsA(_rejected(403, 'Outside lecture hall variance boundary')
            .having((e) => e.body['distance_m'], 'distance_m', closeTo(150.0, 0.1))),
      );
    });

    test('c. a mocked location is rejected', () async {
      await expectLater(hall.mark(_loc(mocked: true), roll: 'C1'), throwsA(_spoof('OS_MOCK_LOCATION_DETECTED')));
    });

    test('c. synthetic 2D coordinates (accuracy 5.0, altitude 0.0, altitude_accuracy 0.0) are rejected', () async {
      await expectLater(
        hall.mark(_loc(accuracy: 5.0, altitude: 0.0, altitudeAccuracy: 0.0), roll: 'C2'),
        throwsA(_spoof('SYNTHETIC_2D_INJECTED_COORDINATES')),
      );
    });

    test('d. a variance-inflation attack (accuracy 500) is rejected', () async {
      await expectLater(
        hall.mark(_loc(accuracy: 500.0), roll: 'D1'),
        throwsA(_spoof('EXCESSIVE_OR_INVALID_GPS_UNCERTAINTY')),
      );
    });

    test('the combined uncertainty is clamped at 50 m, so a vague fix cannot open the geofence', () async {
      // student sigma 60.5 -> combined 61.1 m, clamped to 50 -> allowed 30 + 50 = 80 m
      final ok = await hall.mark(_loc(lat: northOf(profLat, 70), accuracy: 60.5), roll: 'K1');
      expect(ok.allowedRadiusM, closeTo(80.0, 0.01));
      await expectLater(
        hall.mark(_loc(lat: northOf(profLat, 85), accuracy: 60.5), roll: 'K2'),
        throwsA(_rejected(403, 'Outside lecture hall variance boundary')
            .having((e) => e.body['allowed_radius_m'], 'allowed_radius_m', closeTo(80.0, 0.01))),
      );
    });

    test('a stale GPS timestamp is rejected', () async {
      final old = hall.nowMs() - 60000;
      await expectLater(hall.mark(_loc(timestamp: old), roll: 'S1'), throwsA(_spoof('STALE_OR_REPLAYED_GPS_TIMESTAMP')));
    });

    test('a frozen two-sample feed (zero jitter, altitude 0) is rejected, a single sample is not', () async {
      await expectLater(
        hall.mark(_loc(accuracy: 7.5, altitude: 0.0, altitudeAccuracy: 2.5, jLat: 0, jLon: 0, jAcc: 0), roll: 'F1'),
        throwsA(_spoof('FROZEN_SYNTHETIC_SENSOR_FEED')),
      );
      final single = await hall.mark(
        _loc(accuracy: 7.5, altitude: 0.0, altitudeAccuracy: 2.5, jLat: 0, jLon: 0, jAcc: 0, samples: 1),
        roll: 'F2',
      );
      expect(single.distanceM, lessThan(1));
    });

    test('impossible indoor precision is rejected when the professor only got a poor indoor fix', () async {
      final indoor = await _Session.start(api, _loc(accuracy: 15.2));
      await expectLater(
        indoor.mark(_loc(accuracy: 1.0, altitude: 210.0, altitudeAccuracy: 3.0), roll: 'P1'),
        throwsA(_spoof('IMPOSSIBLE_INDOOR_SATELLITE_PRECISION')),
      );
      // the same student is fine when the professor's own fix was good
      final ok = await hall.mark(_loc(accuracy: 1.0, altitude: 210.0, altitudeAccuracy: 3.0), roll: 'P2');
      expect(ok.alreadyMarked, isFalse);
      await api.stopSession(indoor.id);
    });

    test('the professor cannot start a session with a mocked location', () async {
      await expectLater(
        api.startSession(location: _loc(mocked: true)),
        throwsA(_rejected(403, 'Professor location cannot be mocked')),
      );
    });

    test('missing location is a 400 for both the professor and the student', () async {
      final base = Uri.parse(url!);
      final start = await http.post(base.resolve('/api/session/start'),
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'}, body: '{}');
      expect(start.statusCode, 400);
      final mark = await http.post(base.resolve('/api/attendance/mark'),
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
          body: jsonEncode({
            'session_id': hall.id,
            'student_roll_no': 'M1',
            'student_name': 'No Location',
            'rolling_code': hall.code(),
            'rssi': -55,
            'device_mac_address': '02:AA:00:00:00:09',
          }));
      expect(mark.statusCode, 400);
    });

    test('e. two roll numbers on one device are both recorded and flagged as proxies', () async {
      const phone = '02:AA:00:00:00:77';
      await hall.mark(_loc(lat: northOf(profLat, 3), accuracy: studentSigma), roll: 'X1', device: phone);
      await hall.mark(_loc(lat: northOf(profLat, 4), accuracy: studentSigma), roll: 'X2', device: phone);

      final report = await api.getReport(hall.id);
      final flagged = report.flagged.where((r) => r.deviceId == phone).toList();
      expect(flagged.map((r) => r.rollNo), ['X1', 'X2']);
      expect(flagged.first.sharedWith, ['X2']);
      expect(flagged.every((r) => r.locationVerified && r.distanceM != null && r.allowedRadiusM != null), isTrue);

      // rejected attempts never reach the report
      final rolls = report.records.map((r) => r.rollNo).toSet();
      expect(rolls, containsAll(['A1', 'K1', 'F2', 'P2', 'X1', 'X2']));
      expect(rolls, isNot(contains('B1')));
      expect(rolls, isNot(contains('C1')));
      expect(rolls, isNot(contains('D1')));
    });
  }, skip: url == null || token == null ? 'set ATTENDANCE_SERVER and ATTENDANCE_TOKEN to run against a live server' : false);
}

/// A telemetry sample with realistic defaults: fractional accuracy, real 3D data and a little jitter,
/// so only the field a test changes can trip a forensic check.
LocationTelemetry _loc({
  double lat = 28.6139,
  double lon = 77.2090,
  double accuracy = 6.7,
  double altitude = 215.4,
  double altitudeAccuracy = 3.2,
  bool mocked = false,
  int? timestamp,
  int samples = 2,
  double jLat = 0.0000012,
  double jLon = 0.0000009,
  double jAcc = 0.4,
}) =>
    LocationTelemetry(
      lat: lat,
      lon: lon,
      accuracy: accuracy,
      altitude: altitude,
      altitudeAccuracy: altitudeAccuracy,
      speed: 0.1,
      timestamp: timestamp ?? DateTime.now().millisecondsSinceEpoch,
      isMocked: mocked,
      sampleCount: samples,
      jitterLatDelta: samples == 1 ? 0 : jLat,
      jitterLonDelta: samples == 1 ? 0 : jLon,
      jitterAccDelta: samples == 1 ? 0 : jAcc,
      wifiBssid: 'aa:bb:cc:dd:ee:01',
    );

TypeMatcher<ApiException> _rejected(int status, String message) =>
    isA<ApiException>().having((e) => e.status, 'status', status).having((e) => e.message, 'message', message);

TypeMatcher<ApiException> _spoof(String reason) => _rejected(403, 'Location authenticity check failed')
    .having((e) => e.body['spoof_reasons'], 'spoof_reasons', contains(reason));

/// A started session plus what a student phone needs to check in to it.
class _Session {
  _Session(this.api, this.id, this.seed, this.hallRadiusM, this.offset);

  final AttendanceApi api;
  final String id;
  final String seed;
  final double hallRadiusM;

  /// Server clock minus ours, the same correction the professor app applies.
  final Duration offset;
  int _devices = 0;

  static Future<_Session> start(AttendanceApi api, LocationTelemetry anchor) async {
    final s = await api.startSession(location: anchor);
    return _Session(api, s.sessionId, s.secretSeed, s.hallRadiusM,
        Duration(milliseconds: s.serverTimestamp - DateTime.now().millisecondsSinceEpoch));
  }

  int nowMs() => DateTime.now().add(offset).millisecondsSinceEpoch;

  /// The code the professor phone would be broadcasting right now.
  String code() => generateRollingCode(seed, now: DateTime.now().add(offset));

  Future<({bool alreadyMarked, double distanceM, double allowedRadiusM})> mark(
    LocationTelemetry location, {
    required String roll,
    String? device,
    int rssi = -55,
  }) =>
      api.markAttendance(
        sessionId: id,
        rollNo: roll,
        name: 'Student $roll',
        rollingCode: code(),
        rssi: rssi,
        deviceId: device ?? '02:AA:00:00:00:${(++_devices).toRadixString(16).padLeft(2, '0')}',
        location: location,
      );
}
