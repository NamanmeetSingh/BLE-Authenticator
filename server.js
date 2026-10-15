const express = require('express');
const crypto = require('crypto');
const Database = require('better-sqlite3');

const PORT = process.env.PORT || 3000;
const RSSI_MIN = -75; // weaker than this = outside the classroom
const STEP_MS = 5000; // rolling-code window

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

const q = {
  getSession: db.prepare('SELECT * FROM sessions WHERE session_id = ?'),
  newSession: db.prepare('INSERT INTO sessions (session_id, secret_seed, started_at) VALUES (?, ?, ?)'),
  stopSession: db.prepare('UPDATE sessions SET is_active = 0, stopped_at = ? WHERE session_id = ? AND is_active = 1'),
  mark: db.prepare(`INSERT OR IGNORE INTO attendance
    (session_id, student_roll_no, student_name, device_mac_address, rssi, timestamp)
    VALUES (?, ?, ?, ?, ?, ?)`),
  records: db.prepare(`SELECT student_roll_no, student_name, device_mac_address, rssi, timestamp
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

function createSession() {
  const secret_seed = crypto.randomBytes(16).toString('hex'); // 32 chars
  // ponytail: 4 hex chars = 65,536 ids; retries on collision, gives up near exhaustion — widen the id or purge old sessions then
  for (let i = 0; i < 100; i++) {
    const session_id = crypto.randomBytes(2).toString('hex').toUpperCase();
    if (q.getSession.get(session_id)) continue;
    q.newSession.run(session_id, secret_seed, new Date().toISOString());
    return { session_id, secret_seed, server_timestamp: Date.now() };
  }
  throw new Error('session id space exhausted');
}

// string or number -> trimmed string, anything else -> ''
const text = (v) => (typeof v === 'string' || typeof v === 'number' ? String(v).trim() : '');

const app = express();
app.use(express.json());

app.post('/api/session/start', (req, res) => {
  res.status(201).json(createSession());
});

app.post('/api/session/stop', (req, res) => {
  const session_id = text((req.body || {}).session_id).toUpperCase();
  if (!session_id) return res.status(400).json({ error: 'session_id is required' });
  if (!q.getSession.get(session_id)) return res.status(404).json({ error: 'unknown session' });
  q.stopSession.run(new Date().toISOString(), session_id); // idempotent
  res.json({ session_id, is_active: false });
});

app.post('/api/attendance/mark', (req, res) => {
  const b = req.body || {};
  const session_id = text(b.session_id).toUpperCase();
  const roll = text(b.student_roll_no);
  const name = text(b.student_name);
  const mac = text(b.device_mac_address).toUpperCase(); // normalise so aa:bb and AA:BB group together
  const { rolling_code, rssi } = b;

  if (!session_id || !roll || !name || !mac || typeof rolling_code !== 'string' || typeof rssi !== 'number' || rssi > 0) {
    return res.status(400).json({
      error: 'expected { session_id, student_roll_no, student_name, rolling_code, rssi (<= 0), device_mac_address }',
    });
  }

  const session = q.getSession.get(session_id);
  if (!session) return res.status(404).json({ error: 'unknown session' });
  if (!session.is_active) return res.status(403).json({ error: 'session is not active' });
  if (rssi < RSSI_MIN) return res.status(403).json({ error: `signal too weak (rssi ${rssi} < ${RSSI_MIN})` });
  if (!codeIsValid(session.secret_seed, rolling_code)) return res.status(401).json({ error: 'invalid rolling code' });

  // Same roll no. marking twice is a no-op (first mark wins). A different roll no. on the same MAC is
  // always recorded — it is only flagged in the report.
  const info = q.mark.run(session_id, roll, name, mac, rssi, new Date().toISOString());
  res.status(info.changes ? 201 : 200).json({ ok: true, already_marked: info.changes === 0 });
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

  const records = rows.map((r) => {
    const others = [...rollsByMac.get(r.device_mac_address)].filter((x) => x !== r.student_roll_no);
    return { ...r, proxy_flagged: others.length > 0, shared_with_roll_nos: others };
  });

  res.json({
    session_id,
    is_active: !!session.is_active,
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

app.listen(PORT, () => console.log(`BLE attendance server on http://localhost:${PORT}`));
