# BLE-Authenticator

![Flutter](https://img.shields.io/badge/Flutter-Cross--Platform-02569B?logo=flutter)
![Node.js](https://img.shields.io/badge/Backend-Node.js%20%7C%20Express-339933?logo=nodedotjs)
![SQLite](https://img.shields.io/badge/Database-SQLite3-003B57?logo=sqlite)
![Protocol](https://img.shields.io/badge/Protocol-BLE%20GATT%20%2F%20Advertising-0082FC?logo=bluetooth)
![Security](https://img.shields.io/badge/Crypto-HMAC--SHA256%20TOTP-critical)

**BLE-Authenticator** is a cryptographic proximity authentication system built on Bluetooth Low Energy (BLE) connectionless broadcasting and short-lived Time-Based One-Time Passwords (TOTP). 

Designed for high-density environments where one-to-many physical presence verification is required without Bluetooth pairing bottlenecks, the system combines **5-second rotating HMAC-SHA256 payloads**, **Received Signal Strength Indicator (RSSI) boundary enforcement**, and **hardware device fingerprinting** to defend against packet replay, real-time network relay, and multi-identity Sybil attacks.

---

## Key Security & Architectural Features

* **Connectionless One-to-Many Broadcasting:** Utilizes BLE Peripheral Advertising rather than traditional GATT pairing, enabling hundreds of client nodes (BLE Centrals) to capture and verify cryptographic beacons concurrently within milliseconds.
* **5-Second Ephemeral Rolling Tokens (TOTP):** Broadcaster nodes and the verification server independently compute rotating 8-character hexadecimal `HMAC-SHA256` tokens from a high-entropy 32-character session seed. Tokens rotate every 5,000 ms with a $\pm 1$ time-step drift tolerance window.
* **Zero-Exposure In-Memory Pipeline:** Broadcast tokens are packed directly into raw BLE advertisement byte frames, parsed in memory during foreground scans, and transmitted over HTTPS to the verification authority—never rendered on-screen or exposed to the user.
* **Physical Proximity Gating (RSSI Attenuation Cutoff):** Enforces a strict `-75 dBm` signal strength threshold on both the client scanner and backend verifier to mitigate through-wall signal leakage and out-of-room relay attempts.
* **Anti-Sybil Hardware Fingerprinting:** Extracts persistent hardware identifiers (`Android ID` / `iOS identifierForVendor` / device MAC correlation) on every authentication handshake, automatically detecting and flagging multiple identities authenticating from a single physical device.

---

## System Architecture & Cryptographic Handshake

```text
+-----------------------+          BLE Advertisement           +-----------------------+
|   Broadcaster Node    |  [UUID | SessionID : RollingToken]   |     Client Node       |
|   (BLE Peripheral)    | ===================================> |     (BLE Central)     |
+-----------------------+        Rotates every 5,000 ms         +-----------------------+
           ^                                                               |
           | 1. POST /api/session/start                                    | 2. Verifies RSSI >= -75 dBm
           |    Receives {session_id, secret_seed}                         |    Extracts Hardware ID
           v                                                               v
+--------------------------------------------------------------------------------------+
|                          Authentication & Verification Server                        |
|                    (Node.js + Express + SQLite3 + HMAC-SHA256 Engine)                |
+--------------------------------------------------------------------------------------+
```

### Cryptographic Token Generation
Both the Broadcaster Node and the Verification Server synchronize state exclusively via the shared `secret_seed` and Unix epoch time ($T_{\text{now}}$ in milliseconds), requiring zero continuous network polling during active broadcasting:

$$\text{TimeStep} = \left\lfloor \frac{T_{\text{now}}}{5000} \right\rfloor$$

$$\text{RollingToken} = \text{Truncate}_{8\text{ hex}}\left(\text{HMAC-SHA256}(\text{SecretSeed}, \text{TimeStep})\right)$$

---

## Repository Structure

```text
BLE-Authenticator/
├── server.js                           # Node.js/Express verification server & SQLite engine
├── package.json                        # Backend dependencies (express, better-sqlite3, cors)
└── mobile/                             # Cross-platform Flutter client (Android & iOS)
    ├── pubspec.yaml                    # Mobile dependencies (BLE peripheral/central, crypto)
    ├── android/                        # Android manifest, BLE permissions & Gradle configs
    ├── ios/                            # iOS Runner Info.plist & CoreBluetooth permissions
    ├── lib/
    │   ├── main.dart                   # Role-switching UI (Broadcaster vs. Client Authenticator)
    │   ├── ble_common.dart             # Shared BLE UUIDs, payload encoders & RSSI constants
    │   ├── totp_helper.dart            # HMAC-SHA256 5-second rolling token generator
    │   ├── ble_professor_service.dart  # BLE Peripheral broadcaster & 5s rotation timer
    │   └── ble_student_service.dart    # Foreground BLE Central scanner & hardware ID extractor
    └── test/
        ├── ble_attendance_test.dart    # Unit tests for TOTP & BLE byte framing
        ├── server_integration_test.dart# End-to-end cryptographic & anti-spoofing tests
        └── widget_test.dart            # UI component verification tests
```

---

## Getting Started

### Prerequisites
* **Node.js** (v18+ recommended) & **npm**
* **Flutter SDK** (v3.19+ recommended)
* **Android Studio / ADB Platform Tools** (for Android deployment) or **Xcode** (for iOS deployment)
* Two physical mobile devices with Bluetooth Low Energy (BLE) hardware support

### 1. Start the Verification Server
From the root directory, install dependencies and launch the local authentication server:

```bash
npm install
node server.js
```
The server initializes the SQLite database (`attendance.db`) and listens on `http://localhost:3000`.

### 2. Build & Run the Mobile Client
In a separate terminal, navigate to the `mobile/` directory and fetch the Flutter packages:

```bash
cd mobile
flutter pub get
flutter run
```

---

## REST API Reference

| Method | Endpoint | Description | Payload / Parameters |
| :--- | :--- | :--- | :--- |
| `POST` | `/api/session/start` | Initializes a new cryptographic session and returns a 4-hex `session_id` and 32-char `secret_seed`. | None |
| `POST` | `/api/session/stop` | Terminates an active session and invalidates further token submissions. | `{ "session_id": "4A9F" }` |
| `POST` | `/api/attendance/mark` | Validates the 5-second rolling token, checks `rssi >= -75`, and logs the hardware fingerprint. | `{ "session_id", "student_roll_no", "student_name", "rolling_code", "rssi", "device_mac_address" }` |
| `GET` | `/api/session/:session_id/report` | Returns all verified authentications and flags duplicate hardware fingerprints (`proxy_flagged: true`). | URL Param: `session_id` |

---

## Hardware Validation & Dual-Phone USB-C Testing

To test over-the-air BLE authentication across two physical Android devices connected to a single workstation via USB-C without requiring a shared LAN:

### 1. Verify Connected Devices & Tunnel Port 3000 Over USB
```bash
adb devices
adb -s <BROADCASTER_DEVICE_ID> reverse tcp:3000 tcp:3000
adb -s <CLIENT_DEVICE_ID> reverse tcp:3000 tcp:3000
```

### 2. Deploy Simultaneously to Both Devices
```bash
cd mobile
flutter run -d all
```

### 3. Execute Over-the-Air Verification Suite
1. **Initialize Broadcaster:** On Device 1, select **Broadcaster (Professor) Mode** and start the beacon. The device will request a seed from `http://127.0.0.1:3000` and begin advertising rotating BLE frames every 5 seconds.
2. **Authenticate Client:** On Device 2, select **Client (Student) Mode**, enter an identity (`ID: 101`), and trigger a foreground scan. Device 2 will capture the over-the-air packet, verify `RSSI >= -75 dBm`, attach its hardware identifier, and submit the token for verification.
3. **Verify Anti-Sybil / Multi-Identity Detection:** On the **same** Device 2, submit a second identity (`ID: 102`). Query the live session report on Device 1 to confirm both identities are automatically correlated and flagged (`proxy_flagged: true`) for sharing an identical hardware fingerprint.

### 4. Run Automated Test Suites
```bash
cd mobile
flutter test
```

---

## Cross-Platform Notes (Android & iOS)

* **Android (SDK 23+):** Uses `BluetoothLeAdvertiser` and `BluetoothLeScanner` with `BLUETOOTH_ADVERTISE`, `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, and `ACCESS_FINE_LOCATION` permissions. Ensure the OS master Location toggle is enabled during BLE scanning.
* **iOS (iOS 13.0+):** Configured with `NSBluetoothAlwaysUsageDescription` and `NSBluetoothPeripheralUsageDescription` in `Info.plist`. All BLE scanning and broadcasting operations execute strictly in the foreground to comply with Apple CoreBluetooth background throttling policies.
