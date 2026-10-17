const express = require('express');
const crypto = require('crypto');
const Database = require('better-sqlite3');

const PORT = process.env.PORT || 3000;
const RSSI_MIN = -75; // weaker than this = outside the classroom
const STEP_MS = 5000; // rolling-code window
const HALL_RADIUS_DEFAULT_M = 30.0;
const SIGMA_CLAMP_M = 50.0; // a huge combined GPS uncertainty must not widen the geofence without limit

// Every /api call needs this bearer token, so a public tunnel URL (it ends up on screens, in logs and in
// demos) is not an open door. Set ACCESS_TOKEN to keep one token across restarts; otherwise one is
// generated for this run and printed at startup.
const MIN_TOKEN_LENGTH = 16;
if (process.env.ACCESS_TOKEN && process.env.ACCESS_TOKEN.length < MIN_TOKEN_LENGTH) {
  console.error(`ACCESS_TOKEN must be at least ${MIN_TOKEN_LENGTH} characters: the tunnel URL is public.`);
  process.exit(1);
}
const TOKEN_GENERATED = !process.env.ACCESS_TOKEN;
const ACCESS_TOKEN = process.env.ACCESS_TOKEN || crypto.randomBytes(24).toString('base64url'); // 32 chars
const tokenDigest = crypto.createHash('sha256').update(ACCESS_TOKEN).digest();

// DB_FILE=:memory: gives a throwaway database
const db = new Database(process.env.DB_FILE || 'attendance.db');
db.exec(`
  CREATE TABLE IF NOT EXISTS sessions (
    session_id  TEXT PRIMARY KEY,
    secret_seed TEXT NOT NULL,
    is_active   INTEGER NOT NULL DEFAULT 1,
    started_at  TEXT NOT NULL,
    stopped_at  TEXT
  );
  CREATE TABLE IF NOT EXISTS attendance (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id         TEXT NOT NULL REFERENCES sessions(session_id),
    student_roll_no    TEXT NOT NULL,
    student_name       TEXT NOT NULL,
    device_mac_address TEXT NOT NULL,
    rssi               INTEGER NOT NULL,
    timestamp          TEXT NOT NULL,
    UNIQUE (session_id, student_roll_no)
  );
`);

// Location columns are added in place, so an attendance.db from an earlier version keeps its data.
// (Names and types below are constants, never user input.)
function addMissingColumns(table, columns) {
  const have = new Set(db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name));
  for (const [name, type] of Object.entries(columns)) {
    if (!have.has(name)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${type}`);
  }
}
addMissingColumns('sessions', {
  prof_lat: 'REAL',
  prof_lon: 'REAL',
  prof_accuracy: 'REAL',
  prof_altitude: 'REAL',
  prof_wifi_bssid: 'TEXT',
  hall_radius_m: `REAL DEFAULT ${HALL_RADIUS_DEFAULT_M}`,
});
addMissingColumns('attendance', {
  student_lat: 'REAL',
  student_lon: 'REAL',
  student_accuracy: 'REAL',
  distance_m: 'REAL',
  allowed_radius_m: 'REAL',
  wifi_bssid_match: 'INTEGER',
  location_verified: 'INTEGER',
  spoof_reasons: 'TEXT',
});

const q = {
  getSession: db.prepare('SELECT * FROM sessions WHERE session_id = ?'),
  newSession: db.prepare(`INSERT INTO sessions
    (session_id, secret_seed, started_at, prof_lat, prof_lon, prof_accuracy, prof_altitude, prof_wifi_bssid, hall_radius_m)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`),
  stopSession: db.prepare('UPDATE sessions SET is_active = 0, stopped_at = ? WHERE session_id = ? AND is_active = 1'),
  mark: db.prepare(`INSERT OR IGNORE INTO attendance
    (session_id, student_roll_no, student_name, device_mac_address, rssi, timestamp,
     student_lat, student_lon, student_accuracy, distance_m, allowed_radius_m,
     wifi_bssid_match, location_verified, spoof_reasons)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`),
  records: db.prepare(`SELECT student_roll_no, student_name, device_mac_address, rssi, timestamp,
    student_accuracy, distance_m, allowed_radius_m, wifi_bssid_match, location_verified, spoof_reasons
    FROM attendance WHERE session_id = ? ORDER BY id`),
};

// The seed is used as a UTF-8 string key (NOT hex-decoded) — phones must do the same.
const codeFor = (seed, step) =>
  crypto.createHmac('sha256', seed).update(String(step)).digest('hex').substring(0, 8);

// Accepts the current step +/- 1 for clock drift. Compares all three (no short-circuit), timing-safe.
function codeIsValid(seed, code) {
  if (!/^[0-9a-f]{8}$/i.test(code)) return false;
  const given = Buffer.from(code.toLowerCase());
  const step = Math.floor(Date.now() / STEP_MS);
  return [step, step - 1, step + 1]
    .map((s) => crypto.timingSafeEqual(given, Buffer.from(codeFor(seed, s))))
    .some(Boolean);
}

// ---------------------------------------------------------------------------
// Location: parsing, forensic checks, geometry
// ---------------------------------------------------------------------------

const num = (v) => typeof v === 'number' && Number.isFinite(v);
const round2 = (v) => Math.round(v * 100) / 100;

// Lower-case colon-separated BSSID, or null. The all-zero / 02:00:00:00:00:00 values are what the OS
// returns when it refuses to reveal the access point, so they carry no information.
function normaliseBssid(raw) {
  if (typeof raw !== 'string') return null;
  const s = raw.trim().toLowerCase();
  if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(s)) return null;
  return s === '02:00:00:00:00:00' || s === '00:00:00:00:00:00' ? null : s;
}

// Validates the shape of a telemetry object (trust boundary) and returns a clean copy, or null.
function parseLocation(raw) {
  const l = raw;
  if (!l || typeof l !== 'object') return null;
  const ok =
    num(l.lat) && Math.abs(l.lat) <= 90 &&
    num(l.lon) && Math.abs(l.lon) <= 180 &&
    num(l.accuracy) && num(l.altitude) && num(l.altitude_accuracy) && num(l.speed) &&
    num(l.timestamp) &&
    typeof l.is_mocked === 'boolean' &&
    (l.sample_count === 1 || l.sample_count === 2) &&
    num(l.jitter_lat_delta) && num(l.jitter_lon_delta) && num(l.jitter_acc_delta) &&
    (l.wifi_bssid === undefined || l.wifi_bssid === null || typeof l.wifi_bssid === 'string');
  if (!ok) return null;
  return {
    lat: l.lat,
    lon: l.lon,
    accuracy: l.accuracy,
    altitude: l.altitude,
    altitude_accuracy: l.altitude_accuracy,
    speed: l.speed,
    timestamp: l.timestamp,
    is_mocked: l.is_mocked,
    sample_count: l.sample_count,
    jitter_lat_delta: l.jitter_lat_delta,
    jitter_lon_delta: l.jitter_lon_delta,
    jitter_acc_delta: l.jitter_acc_delta,
    wifi_bssid: normaliseBssid(l.wifi_bssid),
  };
}

// Root-agnostic forensics: none of these need the phone to be trustworthy, they look for the
// fingerprints that naive spoofers leave in the telemetry. All checks run so every reason is reported.
// ponytail: client-reported telemetry, so a hand-crafted payload with realistic jitter, a fractional
// accuracy and a non-zero altitude passes. The BLE rolling code + RSSI is what ties a student to the room.
function evaluateLocationAuthenticity(loc, profLoc, serverNow) {
  const reasons = [];

  // 1. Native OS mock flag (Android isMock(), iOS isSimulatedBySoftware / isProducedByAccessory)
  if (loc.is_mocked === true) reasons.push('OS_MOCK_LOCATION_DETECTED');

  // 2. Fix older (or newer) than 20 s relative to the server clock
  if (Math.abs(serverNow - loc.timestamp) > 20000) reasons.push('STALE_OR_REPLAYED_GPS_TIMESTAMP');

  // 3. Variance inflation guard
  if (loc.accuracy <= 0 || loc.accuracy > 65.0) reasons.push('EXCESSIVE_OR_INVALID_GPS_UNCERTAINTY');

  // 4. Clean integer accuracy and no 3D data: typical of injected 2D coordinates
  if (Number.isInteger(loc.accuracy) && loc.altitude === 0 && loc.altitude_accuracy === 0) {
    reasons.push('SYNTHETIC_2D_INJECTED_COORDINATES');
  }

  // 5. Satellite-grade precision claimed in a hall where the professor can only get a poor indoor fix
  if (profLoc && profLoc.accuracy > 12.0 && loc.accuracy < 2.0 && Number.isInteger(loc.accuracy)) {
    reasons.push('IMPOSSIBLE_INDOOR_SATELLITE_PRECISION');
  }

  // 6. Two samples with literally zero movement in every field: a frozen feed
  if (
    loc.sample_count >= 2 &&
    loc.jitter_lat_delta === 0 && loc.jitter_lon_delta === 0 && loc.jitter_acc_delta === 0 &&
    loc.altitude === 0
  ) {
    reasons.push('FROZEN_SYNTHETIC_SENSOR_FEED');
  }

  return { isAuthentic: reasons.length === 0, reasons };
}

// Great-circle distance in metres.
function haversineM(lat1, lon1, lat2, lon2) {
  const rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad;
  const dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(a));
}

// Same access point (or sibling radios of one router): first 5 of 6 octets equal.
// null when either side has no usable BSSID.
function bssidMatch(a, b) {
  if (!a || !b) return null;
  return a.split(':').slice(0, 5).join(':') === b.split(':').slice(0, 5).join(':') ? 1 : 0;
}

// ---------------------------------------------------------------------------

function createSession(location, hall_radius_m) {
  const secret_seed = crypto.randomBytes(16).toString('hex'); // 32 chars
  // ponytail: 4 hex chars = 65,536 ids; retries on collision, gives up near exhaustion — widen the id or purge old sessions then
  for (let i = 0; i < 100; i++) {
    const session_id = crypto.randomBytes(2).toString('hex').toUpperCase();
    if (q.getSession.get(session_id)) continue;
    q.newSession.run(
      session_id, secret_seed, new Date().toISOString(),
      location.lat, location.lon, location.accuracy, location.altitude, location.wifi_bssid, hall_radius_m,
    );
    console.log(`  session ${session_id} started: anchor accuracy ±${location.accuracy}m, hall radius ${hall_radius_m}m`); // never log the seed or coordinates
    return { session_id, secret_seed, server_timestamp: Date.now(), hall_radius_m };
  }
  throw new Error('session id space exhausted');
}

// string or number -> trimmed string, anything else -> ''
const text = (v) => (typeof v === 'string' || typeof v === 'number' ? String(v).trim() : '');

const app = express();
// one line per request: method, path, status (bodies and headers are never logged: they carry rolling
// codes, coordinates and the access token)
app.use((req, res, next) => {
  res.on('finish', () => console.log(`${new Date().toISOString()} ${req.method} ${req.originalUrl} -> ${res.statusCode}`));
  next();
});

// Token check first, before any body is parsed: an unauthenticated caller learns nothing, not even
// whether its payload was valid. Hashing both sides makes the comparison constant-time for any length.
app.use('/api', (req, res, next) => {
  const bearer = /^Bearer\s+(.+)$/i.exec(req.get('authorization') || '');
  const given = crypto.createHash('sha256').update(bearer ? bearer[1].trim() : '').digest();
  if (crypto.timingSafeEqual(given, tokenDigest)) return next();
  res.set('WWW-Authenticate', 'Bearer').status(401).json({ error: 'missing or invalid access token' });
});

app.use(express.json());

// The app's "Test connection" button: reachable, and the token was accepted.
app.get('/api/ping', (req, res) => res.json({ ok: true }));

app.post('/api/session/start', (req, res) => {
  const b = req.body || {};
  const location = parseLocation(b.location);
  if (!location) {
    return res.status(400).json({
      error: 'location is required: { lat, lon, accuracy, altitude, altitude_accuracy, speed, timestamp, is_mocked, sample_count, jitter_lat_delta, jitter_lon_delta, jitter_acc_delta, wifi_bssid }',
    });
  }
  const hall_radius_m = b.hall_radius_m === undefined ? HALL_RADIUS_DEFAULT_M : b.hall_radius_m;
  if (!num(hall_radius_m) || hall_radius_m <= 0 || hall_radius_m > 1000) {
    return res.status(400).json({ error: 'hall_radius_m must be a number in (0, 1000]' });
  }

  if (location.is_mocked === true) return res.status(403).json({ error: 'Professor location cannot be mocked' });
  const { isAuthentic, reasons } = evaluateLocationAuthenticity(location, null, Date.now());
  if (!isAuthentic) {
    console.log(`  session start rejected: ${reasons.join(', ')}`);
    return res.status(403).json({ error: 'Professor location failed authenticity check', spoof_reasons: reasons });
  }

  res.status(201).json(createSession(location, hall_radius_m));
});

app.post('/api/session/stop', (req, res) => {
  const session_id = text((req.body || {}).session_id).toUpperCase();
  if (!session_id) return res.status(400).json({ error: 'session_id is required' });
  if (!q.getSession.get(session_id)) return res.status(404).json({ error: 'unknown session' });
  q.stopSession.run(new Date().toISOString(), session_id); // idempotent
  console.log(`  session ${session_id} stopped`);
  res.json({ session_id, is_active: false });
});

app.post('/api/attendance/mark', (req, res) => {
  const b = req.body || {};
  const session_id = text(b.session_id).toUpperCase();
  const roll = text(b.student_roll_no);
  const name = text(b.student_name);
  const mac = text(b.device_mac_address).toUpperCase(); // normalise so aa:bb and AA:BB group together
  const { rolling_code, rssi } = b;
  const location = parseLocation(b.location);

  if (!session_id || !roll || !name || !mac || typeof rolling_code !== 'string' || typeof rssi !== 'number' || rssi > 0 || !location) {
    return res.status(400).json({
      error: 'expected { session_id, student_roll_no, student_name, rolling_code, rssi (<= 0), device_mac_address, location }',
    });
  }

  const session = q.getSession.get(session_id);
  if (!session) return res.status(404).json({ error: 'unknown session' });
  if (!session.is_active) return res.status(403).json({ error: 'session is not active' });
  if (rssi < RSSI_MIN) return res.status(403).json({ error: `signal too weak (rssi ${rssi} < ${RSSI_MIN})` });
  if (!codeIsValid(session.secret_seed, rolling_code)) return res.status(401).json({ error: 'invalid rolling code' });
  if (session.prof_lat === null) return res.status(403).json({ error: 'session has no location anchor' }); // pre-upgrade session

  // Step A: forensic authenticity of the student's telemetry
  const profLoc = { lat: session.prof_lat, lon: session.prof_lon, accuracy: session.prof_accuracy, altitude: session.prof_altitude };
  const { isAuthentic, reasons } = evaluateLocationAuthenticity(location, profLoc, Date.now());
  if (!isAuthentic) {
    console.log(`  mark rejected roll=${roll} spoof_reasons=${reasons.join(',')}`);
    return res.status(403).json({ error: 'Location authenticity check failed', spoof_reasons: reasons });
  }

  // Step B: distance against the hall radius widened by the combined GPS uncertainty (root-sum-square, clamped)
  const distance_m = round2(haversineM(profLoc.lat, profLoc.lon, location.lat, location.lon));
  const combinedSigma = Math.sqrt(profLoc.accuracy ** 2 + location.accuracy ** 2);
  const allowed_radius_m = round2(session.hall_radius_m + Math.min(combinedSigma, SIGMA_CLAMP_M));
  if (distance_m > allowed_radius_m) {
    console.log(`  mark rejected roll=${roll} distance=${distance_m}m allowed=${allowed_radius_m}m`);
    return res.status(403).json({ error: 'Outside lecture hall variance boundary', distance_m, allowed_radius_m });
  }

  // Step C: record. Same roll no. marking twice is a no-op (first mark wins). A different roll no. on the
  // same MAC is always recorded: it is only flagged in the report.
  const info = q.mark.run(
    session_id, roll, name, mac, rssi, new Date().toISOString(),
    location.lat, location.lon, location.accuracy, distance_m, allowed_radius_m,
    bssidMatch(session.prof_wifi_bssid, location.wifi_bssid), 1, JSON.stringify(reasons),
  );
  console.log(`  mark session=${session_id} roll=${roll} name=${name} rssi=${rssi} distance=${distance_m}m allowed=${allowed_radius_m}m device=${mac} ${info.changes ? 'recorded' : 'already marked'}`);
  res.status(info.changes ? 201 : 200).json({ ok: true, already_marked: info.changes === 0, distance_m, allowed_radius_m });
});

app.get('/api/session/:session_id/report', (req, res) => {
  const session_id = req.params.session_id.toUpperCase();
  const session = q.getSession.get(session_id);
  if (!session) return res.status(404).json({ error: 'unknown session' });

  const rows = q.records.all(session_id);
  const rollsByMac = new Map();
  for (const r of rows) {
    if (!rollsByMac.has(r.device_mac_address)) rollsByMac.set(r.device_mac_address, new Set());
    rollsByMac.get(r.device_mac_address).add(r.student_roll_no);
  }

  // Raw student coordinates stay in the database; the report only carries what the professor needs.
  const records = rows.map((r) => {
    const others = [...rollsByMac.get(r.device_mac_address)].filter((x) => x !== r.student_roll_no);
    return {
      student_roll_no: r.student_roll_no,
      student_name: r.student_name,
      device_mac_address: r.device_mac_address,
      rssi: r.rssi,
      timestamp: r.timestamp,
      student_accuracy: r.student_accuracy,
      distance_m: r.distance_m,
      allowed_radius_m: r.allowed_radius_m,
      wifi_bssid_match: r.wifi_bssid_match === null ? null : r.wifi_bssid_match === 1,
      location_verified: r.location_verified === 1,
      spoof_reasons: JSON.parse(r.spoof_reasons || '[]'),
      proxy_flagged: others.length > 0,
      shared_with_roll_nos: others,
    };
  });

  res.json({
    session_id,
    is_active: !!session.is_active,
    hall_radius_m: session.hall_radius_m,
    total_records: records.length,
    proxy_flagged_count: records.filter((r) => r.proxy_flagged).length,
    records,
  });
});

// body-parser errors (bad JSON etc.) carry err.status; anything else is a 500
app.use((err, req, res, next) => {
  if (!err.status) console.error(err);
  res.status(err.status || 500).json({ error: err.status ? err.message : 'internal error' });
});

app.listen(PORT, () => {
  console.log(`BLE attendance server on http://localhost:${PORT}`);
  console.log(
    TOKEN_GENERATED
      ? `Access token (generated for this run): ${ACCESS_TOKEN}\n  Set ACCESS_TOKEN to keep the same token across restarts.`
      : `Access token: taken from ACCESS_TOKEN (${ACCESS_TOKEN.length} characters)`,
  );
  console.log(`Demo without USB: in a second terminal run  cloudflared tunnel --url http://localhost:${PORT}`);
  console.log('  then enter the https://<name>.trycloudflare.com URL and the access token in the app.');
});
