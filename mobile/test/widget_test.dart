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
    expect(find.text('Scan & Mark Attendance'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.text('Professor Mode'), findsOneWidget);
    expect(find.text('Start Attendance Broadcast'), findsOneWidget);
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
