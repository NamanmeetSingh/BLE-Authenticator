import 'dart:convert';

import 'package:ble_attendance/ble_common.dart';
import 'package:ble_attendance/ble_student_service.dart';
import 'package:ble_attendance/totp_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rolling code matches the Phase 1 server (server.js codeFor)', () {
    const seed = '847a6fafbb266df2da556415bbec1c17';
    String at(int ms, [String s = seed]) =>
        generateRollingCode(s, now: DateTime.fromMillisecondsSinceEpoch(ms));

    // Expected values were produced by the server's formula in Node:
    // HMAC-SHA256(key = seed as UTF-8 string, msg = floor(ms / 5000)), first 8 hex chars.
    expect(at(1792059699764), '110eaa2e');
    expect(at(1792059699999), '110eaa2e'); // same 5 s step
    expect(at(1792059700000), '7540d1f5'); // next step
    expect(at(1792059699764, '0123456789abcdef0123456789abcdef'), '64bd855e');
  });

  test('beacon payload round-trips; foreign packets are ignored', () {
    expect(decodeBeacon(encodeBeacon('4A9F', 'deadbeef')), (sessionId: '4A9F', rollingCode: 'deadbeef'));
    expect(decodeBeacon(utf8.encode('4a9f:DEADBEEF')), (sessionId: '4A9F', rollingCode: 'deadbeef'));
    expect(decodeBeacon(utf8.encode('hello')), isNull);
    expect(decodeBeacon(utf8.encode('4A9F:deadbee')), isNull); // truncated
    expect(decodeBeacon([0xFF, 0xFE, 0x00]), isNull); // not UTF-8
  });

  test('ProfessorBeacon never prints the rolling code', () {
    const b = ProfessorBeacon(sessionId: '4A9F', rollingCode: 'deadbeef', rssi: -60);
    expect('$b', isNot(contains('deadbeef')));
  });

  test('hardware id is MAC-shaped, stable per phone and locally administered', () {
    final id = macStyleId('some-android-id');
    expect(id, matches(RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$')));
    expect(macStyleId('some-android-id'), id);
    expect(macStyleId('another-phone'), isNot(id));
    expect(int.parse(id.substring(0, 2), radix: 16) & 0x03, 0x02);
  });
}
