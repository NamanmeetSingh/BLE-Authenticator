import 'package:ble_attendance/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('config bar switches between the student and professor screens', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const AttendanceApp());
    expect(find.text('Backend Server URL'), findsOneWidget);
    expect(find.text('http://127.0.0.1:3000'), findsOneWidget);
    expect(find.text('Access Token'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('Student Mode'), findsOneWidget);
    expect(find.text('Verify Both & Mark Attendance'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.text('Professor Mode'), findsOneWidget);
    expect(find.text('Start Attendance Broadcast'), findsOneWidget);
  });

  testWidgets('the server URL and access token are remembered and restored', (tester) async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://calm-river.trycloudflare.com',
      'access_token': 'a-saved-demo-token',
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const AttendanceApp());
    await tester.pumpAndSettle();

    TextField field(String label) => tester.widget<TextField>(find.widgetWithText(TextField, label));
    expect(field('Backend Server URL').controller!.text, 'https://calm-river.trycloudflare.com');
    expect(field('Access Token').controller!.text, 'a-saved-demo-token');
    expect(field('Access Token').obscureText, isTrue); // hidden until the eye icon is tapped

    // an edit is saved straight away
    await tester.enterText(find.widgetWithText(TextField, 'Backend Server URL'), 'https://new-name.trycloudflare.com');
    await tester.pump();
    expect((await SharedPreferences.getInstance()).getString('server_url'), 'https://new-name.trycloudflare.com');

    // and plain http off the phone is called out
    await tester.enterText(find.widgetWithText(TextField, 'Backend Server URL'), 'http://192.168.1.7:3000');
    await tester.pump();
    expect(find.textContaining('Plain http'), findsOneWidget);
  });

  test('server URLs: tunnels default to https, local addresses to http, and plain http off-device is flagged', () {
    expect(AttendanceApi.parseBaseUrl('calm-river.trycloudflare.com').toString(), 'https://calm-river.trycloudflare.com');
    expect(AttendanceApi.parseBaseUrl(' https://x.trycloudflare.com ').toString(), 'https://x.trycloudflare.com');
    expect(AttendanceApi.parseBaseUrl('127.0.0.1:3000').toString(), 'http://127.0.0.1:3000');
    expect(AttendanceApi.parseBaseUrl('192.168.1.7:3000').scheme, 'http');

    expect(plainHttpWarning('https://x.trycloudflare.com'), isNull);
    expect(plainHttpWarning('x.trycloudflare.com'), isNull); // no scheme: https
    expect(plainHttpWarning('http://127.0.0.1:3000'), isNull); // USB: stays on the phone
    expect(plainHttpWarning('http://192.168.1.7:3000'), isNotNull);
    expect(plainHttpWarning('http://x.trycloudflare.com'), isNotNull);
  });

  test('a bad access token is told apart from an expired rolling code (both are 401)', () {
    expect(const ApiException(401, AttendanceApi.authError).isAuthFailure, isTrue);
    expect(const ApiException(401, 'invalid rolling code').isAuthFailure, isFalse);
    expect(describeError(const ApiException(401, AttendanceApi.authError)), contains('access token'));
    expect(describeError(const FormatException('bad')), 'That server URL is not valid.');
  });

  testWidgets('student screen shows each check as its own step, and needs a name and roll first', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2400);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const AttendanceApp());

    // three separate steps, each starting unchecked
    expect(find.text('Step 1 · Bluetooth proximity'), findsOneWidget);
    expect(find.text('Step 2 · Location'), findsOneWidget);
    expect(find.text('Step 3 · Attendance submission'), findsOneWidget);
    expect(find.text('Not checked yet'), findsNWidgets(2));
    expect(find.text('Waiting for both checks'), findsOneWidget);
    expect(find.text('Verify Bluetooth'), findsOneWidget);
    expect(find.text('Verify Location'), findsOneWidget);

    // with no name or roll number nothing runs: the submit step explains why and the checks stay idle
    await tester.tap(find.text('Verify Both & Mark Attendance'));
    await tester.pump();
    expect(find.text('Enter your name and roll number'), findsOneWidget);
    expect(find.text('Not checked yet'), findsNWidgets(2));
  });

  test('GPS summary line and the new report fields parse', () {
    expect(gpsSummary(4.24, 46.52), 'Distance: 4.2m (Bound: 46.5m) • GPS Verified');
    final r = AttendanceRecord.fromJson({
      'student_roll_no': '1',
      'student_name': 'N',
      'device_mac_address': 'AA',
      'rssi': -40,
      'proxy_flagged': false,
      'shared_with_roll_nos': <String>[],
      'distance_m': 4.24,
      'allowed_radius_m': 46.52,
      'location_verified': true,
    });
    expect([r.distanceM, r.allowedRadiusM, r.locationVerified], [4.24, 46.52, true]);
  });

  test('report splits verified from flagged, with shared phones grouped', () {
    Map<String, dynamic> rec(String roll, String mac, {List<String> shared = const []}) => {
          'student_roll_no': roll,
          'student_name': 'N$roll',
          'device_mac_address': mac,
          'rssi': -60,
          'timestamp': '2026-01-01T00:00:00Z',
          'proxy_flagged': shared.isNotEmpty,
          'shared_with_roll_nos': shared,
        };
    final report = AttendanceReport.fromJson({
      'records': [
        rec('3', 'BB', shared: ['4']),
        rec('1', 'AA'),
        rec('2', 'AA2', shared: ['5']),
        rec('4', 'BB', shared: ['3']),
        rec('5', 'AA2', shared: ['2']),
      ],
    });
    expect(report.verified.map((r) => r.rollNo), ['1']);
    expect(report.flagged.map((r) => r.rollNo), ['2', '5', '3', '4']);
  });
}
