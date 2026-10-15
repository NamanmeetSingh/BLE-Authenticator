import 'dart:io';

import 'package:ble_attendance/main.dart';
import 'package:ble_attendance/totp_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs the professor and student protocol against a live Phase 1 server (everything except
/// the BLE radio). Start the server, then:
///   ATTENDANCE_SERVER=http://127.0.0.1:3000 flutter test test/server_integration_test.dart
void main() {
  final url = Platform.environment['ATTENDANCE_SERVER'];

  test('professor and student flows against the real server', () async {
    final api = AttendanceApi(url!);
    final s = await api.startSession();
    expect(s.sessionId, matches(RegExp(r'^[0-9A-F]{4}$')));
    expect(s.secretSeed, hasLength(32));

    // exactly what the professor phone broadcasts, shifted to the server clock like the app does
    final offset = Duration(milliseconds: s.serverTimestamp - DateTime.now().millisecondsSinceEpoch);
    String code() => generateRollingCode(s.secretSeed, now: DateTime.now().add(offset));

    Future<bool> mark(String roll, String device, {int rssi = -60, String? rollingCode}) => api.markAttendance(
          sessionId: s.sessionId,
          rollNo: roll,
          name: 'Student $roll',
          rollingCode: rollingCode ?? code(),
          rssi: rssi,
          deviceId: device,
        );

    expect(await mark('21CS01', '02:AA:00:00:00:01'), isFalse);
    expect(await mark('21CS01', '02:AA:00:00:00:01'), isTrue); // repeat is a no-op
    expect(await mark('21CS02', '02:AA:00:00:00:01'), isFalse); // second student, same phone
    expect(await mark('21CS03', '02:AA:00:00:00:03'), isFalse);

    await expectLater(mark('21CS04', '02:AA:00:00:00:04', rssi: -80), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));
    await expectLater(mark('21CS04', '02:AA:00:00:00:04', rollingCode: 'deadbeef'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));

    final report = await api.getReport(s.sessionId);
    expect(report.verified.map((r) => r.rollNo), ['21CS03']);
    expect(report.flagged.map((r) => r.rollNo), ['21CS01', '21CS02']);
    expect(report.flagged.first.sharedWith, ['21CS02']);

    await api.stopSession(s.sessionId);
    await expectLater(mark('21CS05', '02:AA:00:00:00:05'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));
  }, skip: url == null ? 'set ATTENDANCE_SERVER=http://127.0.0.1:3000 to run against a live server' : false);
}
