import 'package:ble_attendance/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('config bar switches between the student and professor screens', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const AttendanceApp());
    expect(find.text('Backend Server URL'), findsOneWidget);
    expect(find.text('http://127.0.0.1:3000'), findsOneWidget);
    expect(find.text('Student Mode'), findsOneWidget);
    expect(find.text('Verify Both & Mark Attendance'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.text('Professor Mode'), findsOneWidget);
    expect(find.text('Start Attendance Broadcast'), findsOneWidget);
  });

  testWidgets('student screen shows each check as its own step, and needs a name and roll first', (tester) async {
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
