# Insight Bridge Protocol (v2)

Contract between **InsightKit** (iOS, Trio pump manager, BLE *central*) and **InsightBridge**
(Android companion app, BLE *peripheral* + Bluetooth Classic link to the Accu-Chek Insight).

Why a bridge: the Insight speaks the proprietary "Sight" protocol over Bluetooth Classic RFCOMM
(SPP UUID `00001101-0000-1000-8000-00805f9b34fb`). iOS apps cannot open RFCOMM to non-MFi
accessories, so an Android device holds the pump link and exposes a small, authenticated,
high-level command API over BLE GATT.

```
 Trio (iPhone)  --BLE GATT, encrypted-->  InsightBridge (Android)  --RFCOMM / Sight-->  Insight pump
   InsightKit                               Sight protocol, pairing,
   PumpManager                              history, alerts
```

Division of responsibility:

- **Bridge** owns everything Sight-specific: pump pairing, SATL/app-layer crypto, keep-alive,
  service activation, reading history, alert handling, idempotent command execution.
- **InsightKit** owns everything LoopKit-specific: dose bookkeeping, absolute→percent TBR
  conversion, uncertain-delivery handling, status highlights, alerts to the user, setup UI.

---

## 1. GATT layout

| Item | UUID | Properties |
|---|---|---|
| Service | `2462D0E9-9BA1-4434-8DFE-75D844AC9945` | primary, advertised |
| `rx` (iPhone → bridge) | `6FAFD9DD-5BCE-4A1D-B262-A61B50AE7842` | write (with response) |
| `tx` (bridge → iPhone) | `7EDC9323-9BFA-4A7E-AFBB-92DEE0F0B917` | notify |

- Advertising: service UUID in the advertisement; the scan response carries **service data** for that
  UUID = the last 4 hex characters of the bridge id, uppercase ASCII (e.g. `A1B2`). The bridge does
  **not** rename the phone's Bluetooth adapter, so there is no `InsightBridge-…` local name; centrals
  must identify bridges by service UUID (and, after pairing, by the `bridgeId`) and must not filter
  by name. Display name: `InsightBridge-` + service data.
- iOS requests the highest MTU; both sides must work with ATT MTU 23 (payload 20).
- The bridge accepts **one** bonded central at a time. A second central is rejected with
  `error.busy` once the frame layer is up.

## 2. Framing

Messages can exceed the MTU, so each GATT write/notification carries one **fragment**:

```
byte 0       : flags   bit0 = FIRST, bit1 = LAST (single-fragment message: 0x03)
byte 1..2    : messageSeq (uint16 BE), same for all fragments of one message
byte 3..n    : fragment payload
```

Fragments of one message are sent in order. A receiver discards a partial message if a FIRST
fragment with a different `messageSeq` arrives, or after 5 s without the LAST fragment.
Maximum reassembled message size: 16 KiB (larger → drop and send `error.tooLarge`).

The reassembled bytes are an **envelope** (§3).

## 3. Envelope and encryption

All messages except the pairing handshake (§4) are encrypted:

```
byte 0       : type    0x01 = plaintext handshake, 0x02 = encrypted
encrypted:
byte 1..8    : counter (uint64 BE), per direction, strictly increasing, starts at 1 per session
byte 9..n-16 : ciphertext  (AES-256-GCM)
last 16      : GCM tag
nonce (12 B) : direction byte (0x01 iPhone→bridge, 0x02 bridge→iPhone) || 0x000000 || counter
AAD          : byte 0 and counter bytes (bytes 0..8)
```

Receivers reject (and drop the connection on) any envelope with a counter ≤ the last accepted
counter for that direction or a failing tag. Plaintext is UTF-8 JSON (§5).

### Keys

- **Long-term key (LTK)**: 32 bytes, established once by pairing (§4). Stored in the iOS
  Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and Android Keystore-wrapped
  storage. Never logged.
- **Session key**: per BLE connection, see §4.2.

## 4. Handshake (type 0x01 plaintext JSON)

### 4.1 Pairing (first time, user present on both devices)

1. iPhone generates an ephemeral P-256 key pair and `nonceI` (16 B) and sends only a
   **commitment** →
   `{"t":"pairStart","v":2,"commit":"<b64 SHA-256(\"InsightBridge commit v2\"||pubI||nonceI)>"}`
   (`pubI` = 65-byte X9.63 uncompressed point, raw bytes, not base64).
2. Bridge (only if the user tapped *"Pair with iPhone"* in the app within the last 120 s,
   else `{"t":"pairReject","reason":"notInPairingMode"}`) stores `commit` and replies with its
   own ephemeral values →
   `{"t":"pairResp","v":2,"pub":"<b64 pubB>","nonce":"<b64 nonceB 16B>","bridgeId":"<hex 8B>"}`
2a. iPhone → `{"t":"pairReveal","pub":"<b64 pubI>","nonce":"<b64 nonceI>"}`.
   Bridge recomputes the commitment and on mismatch replies
   `{"t":"pairReject","reason":"commitMismatch"}` and discards the attempt.
   (The commitment fixes the iPhone's values before it sees the bridge's, so a man-in-the-middle
   cannot search for values that make both 6-digit codes match; success chance stays 1e-6.)
   A bridge accepts at most one pairing attempt per pairing window.
3. Both compute `Z = ECDH(own priv, peer pub)` and
   `LTK = HKDF-SHA256(ikm=Z, salt=nonceI||nonceB, info="InsightBridge LTK v1", 32)`.
4. Both display a 6-digit **confirmation code**
   `SAS = uint32BE(HMAC-SHA256(LTK, "SAS")[0..3]) mod 1_000_000`, zero-padded.
   The user confirms the codes match **on both devices**.
5. iPhone → encrypted-free `{"t":"pairConfirm","mac":"<b64 HMAC-SHA256(LTK,\"confirm-i\")>"}`
   only after the user confirms on iOS. Bridge verifies, waits for the user's confirmation on
   Android, then replies `{"t":"pairDone","mac":"<b64 HMAC-SHA256(LTK,\"confirm-b\")>"}`.
   Either side aborting → `{"t":"pairReject","reason":"userRejected"}`; nothing is stored.
6. Both persist LTK + peer identity (`bridgeId` / iOS-generated `clientId`, hex 8B, sent in
   `sessionStart`). Pairing a new iPhone replaces the previous one on the bridge.

### 4.2 Session start (every connection)

1. iPhone → `{"t":"sessionStart","v":2,"clientId":"<hex>","nonce":"<b64 16B>"}`
2. Bridge → `{"t":"sessionResp","v":2,"bridgeId":"<hex>","nonce":"<b64 16B>",
   "mac":"<b64 HMAC-SHA256(LTK, \"session\"||nonceI||nonceB)>"}` or
   `{"t":"sessionReject","reason":"unknownClient"}` (→ iOS shows "re-pair bridge").
3. iOS verifies `mac`. `SK = HKDF-SHA256(ikm=LTK, salt=nonceI||nonceB, info="InsightBridge SK v1", 32)`.
4. iPhone sends its first encrypted message (`hello`, §5). Bridge drops the link if no valid
   encrypted message arrives within 10 s.

## 5. Application messages (encrypted JSON)

Requests: `{"id": <uint32, unique per session>, "op": "<name>", "args": {...}}`
Responses: `{"id": <same>, "ok": true, "result": {...}}` or
`{"id": <same>, "ok": false, "error": {"code": "<code>", "message": "<human, English>",
 "uncertain": <bool>}}`
Events (unsolicited): `{"evt": "<name>", "data": {...}}`

`uncertain: true` means the bridge **cannot tell** whether the pump executed the command
(e.g. pump link lost after sending). InsightKit must map this to LoopKit's uncertain-delivery
path and must **not** retry dosing commands automatically.

Timeouts (iOS side): status ops 30 s, dosing ops 45 s. A timeout on a dosing op is treated as
uncertain; InsightKit then resolves it with `getRequestOutcome` first (authoritative when it
returns `succeeded`/`failed`), and only falls back to `getStatus` + `readHistory` evidence when the
bridge says `unknown`/`uncertain`. `inProgress` means wait and ask again; never resend.

`getRequestOutcome` semantics (bridge): `unknown` = requestId never received (or older than 24 h);
`inProgress` = received and still executing / queued toward the pump; `succeeded`/`failed` = final
outcome with the same `result`/`error` the original response carried; `uncertain` = the bridge
itself lost the pump link mid-command and cannot tell. Bridges record the requestId as
`inProgress` **before** talking to the pump.

Units: insulin in **U** (decimal number), rates in **U/h**, durations in **minutes**,
timestamps ISO-8601 UTC with `Z`, pump-local times additionally as `pumpLocal` strings.

### 5.1 Operations

| op | args | result |
|---|---|---|
| `hello` | `{"protocol":2,"app":"Trio x.y"}` | `{"protocol":2,"bridgeVersion":"…","pumpPaired":bool}` |
| `getStatus` | – | **Status** object (§5.2) |
| `deliverBolus` | `{"amount":U,"requestId":"<uuid>"}` | `{"bolusId":int,"amount":U}` |
| `cancelBolus` | `{"bolusId":int}` | `{"delivered":U \| null}` |
| `setTBR` | `{"percent":int,"duration":min,"requestId":"<uuid>"}` | `{"percent":int,"duration":min}` |
| `cancelTBR` | `{"requestId":"<uuid>"}` | `{}` |
| `setOperatingMode` | `{"mode":"started"\|"stopped","requestId":"<uuid>"}` | `{"mode":…}` |
| `setBasalProfile` | `{"segments":[{"duration":min,"rate":U/h},…],"requestId":"<uuid>"}` | `{"activeProfile":1}` |
| `setDateTime` | `{"utc":"…","tzOffsetMinutes":int}` | `{}` |
| `readHistory` | `{"sinceSequence":int\|null,"max":int (≤200)}` | `{"events":[HistoryEvent],"lastSequence":int,"more":bool}` |
| `confirmAlert` | `{"alertId":int,"alertType":"…"}` | `{}` |
| `snoozeAlert` | `{"alertId":int,"alertType":"…"}` | `{}` |
| `getRequestOutcome` | `{"requestId":"<uuid>"}` | `{"state":"unknown"\|"inProgress"\|"succeeded"\|"failed"\|"uncertain","result":{…}\|null,"error":{…}\|null,"completedAt":"…Z"\|null}` |
| `pumpPairingStatus` | – | `{"paired":bool,"serial":str\|null,"bridgeBluetoothOn":bool}` |

Rules:

- **Idempotency.** Every dosing/state-changing op carries `requestId`. The bridge keeps the
  outcome of the last 64 `requestId`s for 24 h (persisted). A repeated `requestId` returns the
  stored outcome without touching the pump. InsightKit generates one `requestId` per user/loop
  intent and reuses it only when explicitly resolving that same intent.
- **Validation on the bridge** (reject with `error.invalidArgs`, never clamp silently):
  - bolus: `0 < amount ≤ min(pump maxBolus, 25)` and a multiple of `limits.bolusStep`
    (the step AndroidAPS uses for the Insight); non-multiples are rejected.
  - TBR: `percent` 0…250 in steps of 10; `duration` 15…1440 in steps of 15.
  - basal profile: 1…24 segments, durations multiples of 60 min (Insight blocks are hourly
    boundaries) summing to 1440, each rate within pump min/max basal and the pump basal step.
- `deliverBolus` responds as soon as the pump has **accepted/started** the bolus (it does not
  wait for completion). Completion is reported via `bolusProgress` events, `status.boluses` and
  the `bolusDelivered` history event.
- `readHistory` with `sinceSequence: null` returns the newest `max` events (oldest first within
  the page) so a first read is bounded; with a number it returns events with `seq > sinceSequence`
  in ascending order.
- `status.basal.rate` is the **scheduled** profile rate at the current pump time, excluding any TBR.
- `setTBR` while a TBR is running replaces it (bridge uses ChangeTBR where applicable).
- `setTBR` with `percent: 100` is invalid; callers use `cancelTBR`.
- `setBasalProfile` writes profile 1 and activates it; the bridge re-reads it and returns
  `error.verifyFailed` if read-back differs.
- When the pump is not in `started` mode, `deliverBolus` and `setTBR` fail with
  `error.pumpSuspended` (not uncertain).

### 5.2 Status object

```json
{
  "timestamp": "2026-11-18T10:00:00Z",
  "pumpLink": "connected" | "connecting" | "disconnected" | "notPaired",
  "serial": "…", "firmware": "…",
  "operatingMode": "started" | "stopped" | "paused",
  "battery": {"percent": 80},
  "reservoir": {"units": 123.45, "cartridgeType": "prefilled"|"selfFilled"|null},
  "basal": {"activeProfile": 1, "rate": 0.85},
  "tbr": null | {"percent": 120, "duration": 60, "remaining": 42, "start": "…Z"},
  "boluses": [{"bolusId": 12, "type": "standard", "amount": 2.0, "remaining": 0.6}],
  "pumpTime": {"utc": "…Z", "pumpLocal": "2026-11-18T11:00:00", "driftSeconds": 3},
  "limits": {"maxBolus": 10.0, "maxBasal": 2.5, "bolusStep": 0.05, "basalStep": 0.01,
             "minBasal": 0.02},
  "activeAlert": null | Alert,
  "lastHistorySequence": 9876
}
```

All fields are present; unknown values are `null`. `timestamp` is when the bridge last read
the pump, not when the message was sent; InsightKit treats status older than 15 min as stale.

### 5.3 HistoryEvent

```json
{"seq": 9876, "time": "…Z", "type": "<type>", "data": {...}}
```

Types and `data`:

| type | data |
|---|---|
| `bolusProgrammed` | `{"bolusId","bolusType","amount"}` |
| `bolusDelivered` | `{"bolusId","bolusType","programmed","delivered","start","end"}` |
| `tbrStart` | `{"percent","duration"}` |
| `tbrEnd` | `{"percent","duration"}` (actual duration) |
| `basalRateChanged` | `{"oldRate","newRate"}` |
| `operatingModeChanged` | `{"oldMode","newMode"}` |
| `cartridgeInserted` / `cartridgeRemoved` | `{"units"}` / `{}` |
| `tubeFilled` / `cannulaFilled` | `{"units"}` |
| `totalDailyDose` | `{"basal","bolus","total","date"}` |
| `alert` | `{"alertId","alertType","category"}` |
| `dateTimeChanged` | `{"old","new"}` |
| `other` | `{"raw":"<name>"}` |

`seq` is the pump's history event sequence number and is strictly increasing.

### 5.4 Alert

```json
{"alertId": 3, "alertType": "W31_CARTRIDGE_LOW", "category": "reminder"|"maintenance"|"warning"|"error",
 "status": "active"|"snoozed", "tbrPercent": null, "remainingInsulin": null}
```

`alertType` uses the current AndroidAPS `AlertType` enum names verbatim (e.g. `ERROR_6`,
`WARNING_31`, `MAINTENANCE_21`, `REMINDER_01`). Receivers must still fall back to `category` for
unknown names.

### 5.5 Events

| evt | data | when |
|---|---|---|
| `status` | Status | after any state change and at least every 5 min while connected |
| `alert` | Alert | new/changed pump alert |
| `bolusProgress` | `{"bolusId","delivered","remaining"}` | during a bolus, ≤ every 2 s |
| `pumpLink` | `{"state":…}` | pump link state change |

### 5.6 Error codes

`notPaired` (bridge has no pump pairing), `pumpUnreachable`, `pumpSuspended`, `pumpBusy`,
`invalidArgs`, `limitExceeded`, `verifyFailed`, `alertActive`, `busy`, `tooLarge`,
`unsupportedProtocol`, `internal`.

## 6. Versioning

`v` / `protocol` = 2 (pairing with commitment, `getRequestOutcome`). v1 is not supported. Breaking changes bump the number; the bridge rejects unknown major
versions with `unsupportedProtocol`. Unknown JSON fields are ignored by both sides.

## 7. Safety invariants (both sides MUST hold)

1. No dosing command is ever retried automatically after an uncertain outcome.
2. The bridge never executes a dosing op whose envelope was not authenticated with the
   current session key.
3. The bridge rejects out-of-range values instead of clamping.
4. The bridge never initiates dosing on its own (it may confirm/snooze alerts only on request,
   and it keeps the pump in sync only for time when asked).
5. Loss of the iPhone link leaves any running TBR to expire on the pump by itself.
