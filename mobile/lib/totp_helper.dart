import 'dart:convert';

import 'package:crypto/crypto.dart';

const _stepMs = 5000;

/// First 8 hex chars of HMAC-SHA256(secretSeed, timeStep), where
/// timeStep = (epoch ms ~/ 5000) as a decimal string. Matches `codeFor()` in the
/// Phase 1 server.js: the seed is the key as a UTF-8 string, NOT hex-decoded bytes.
///
/// The code lives in memory only: never put it in a widget, a log line or storage.
/// [now] is for tests (or for shifting by the server_timestamp offset if phone clocks drift).
String generateRollingCode(String secretSeed, {DateTime? now}) {
  final timeStep = ((now ?? DateTime.now()).millisecondsSinceEpoch ~/ _stepMs).toString();
  final mac = Hmac(sha256, utf8.encode(secretSeed)).convert(utf8.encode(timeStep));
  return mac.toString().substring(0, 8); // Digest.toString() is lowercase hex
}
