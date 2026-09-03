# AC6000 MKIII BT BLE protocol

BLE communication spec for the Acetech AC6000 MKIII BT.

> **This document is a measured spec (based on PacketLogger captures and real-hardware
> follow-up tests) and is authoritative in this repository.**
> It contains only observations from communication captures we recorded ourselves and
> follow-up tests against the real device made with our own client. It does not include
> anything derived from reverse-engineering another app's binary.

Status: **confirmed against real-hardware ground truth** (Phase 1b complete; device log
confirmed 2026-09-03/04)

## 0. Sources and confidence legend

| | |
|---|---|
| Capture | `tools/re/captures/acesoft-iphone.pklg` (Apple PacketLogger, iPhone HCI log) |
| Extracted | `tools/re/notes/pklg-att.tsv` (raw) / `tools/re/notes/pklg-timeline.txt` (readable timeline) |
| Fixtures | `Tests/MuzzlemeterKitTests/Fixtures/acesoft-iphone-{rx,tx}.txt` |
| Peer | AceSoft (iOS) ⇄ `AC6000BT-009809` (`54:dc:e9:db:f6:0c`, public address) |
| Contents | connect → GATT discovery → key handshake → init → 5 hand-thrown BBs → unit switch → power off |
| Duration | ~104 s / 66 ATT frames (8 app-layer TX / 16 app-layer RX) |
| Additional captures | `tools/re/captures/20260903-222919.log`, `20260904-000619.log`, `20260904-000817.log` — our own sniffer (`muzzlemeter-sniff dump --read-log`), used to confirm the device log (`0x62`/`0x63`) format |

Confidence: **confirmed** = directly evidenced in a capture / **inferred** = consistent but
not conclusive on its own / **unverified** = implemented this way but never observed in a
capture or follow-up test.

> ✅ The speed scale (§7.3) is **confirmed against the device's own LCD** (÷100 → m/s).
> ✅ The device log (§6.5 / §6.6) is **confirmed against real hardware** (2026-09-03/04):
> `0x62` reports the record count, `0x63` reads one record with a 1-based index, and the
> speed matched the device's own LCD history for three hand-thrown BBs.
> ⚠️ The ammo preset weight scale (§6.4) is still **inferred**: the real device showed a
> value in the same slot that ×100 cannot explain (`0x00c8` = 200). See §10.

---

## 1. Device identification

### 1.1 Advertisement

29 advertisements recorded. All payloads identical.

```
02 01 06                                    Flags: LE General Discoverable | BR/EDR Not Supported
11 09 41 43 36 30 30 30 42 54 2d 30 30 39 38 30 39 00
                                            Complete Local Name (0x09), 16 bytes
                                            = "AC6000BT-009809" + NUL padding
08 ff 00 05 08 c4 94 52 04                  Manufacturer Specific Data (0xFF), 7 bytes
```

Manufacturer Specific Data breakdown (**inferred**):

| offset | bytes | meaning |
|---|---|---|
| 0..1 | `00 05` | company id (LE = `0x0500`. Not a real Bluetooth SIG assignment) |
| 2 | `08` | model code? (inferred: AC6000 = 8) |
| **3** | **`c4`** | **key1** |
| **4** | **`94`** | **key2** |
| 5..6 | `52 04` | unknown (does not match serial `009809` = `0x2651`) |

> **Important**: offset 3/4 `c4 94` **exactly matches** the `key1`/`key2` the app sent
> back in the `0x4B` frame right after this. The device very likely carries its pairing
> key in the advertisement itself (**inferred** / see §4.3).

### 1.2 Post-connection identification

| Item | Value |
|---|---|
| GAP Device Name (`0x2A00`, handle `0x000B`) | `ACETECH-12345678` |
| BD_ADDR | `54:dc:e9:db:f6:0c` (public. OUI = Silicon Laboratories) |

**Match on scan using a prefix match on the advertised name `AC6000BT-`.**
`0x2A00` is likely `ACETECH-12345678` on every unit and cannot be used for identification.

---

## 2. GATT layout

Attribute table observed in the capture (**confirmed**).

| handles | UUID | role |
|---|---|---|
| `0x0001`–`0x0008` | `0x1801` | GATT (Service Changed / Database Hash / Client Supported Features) |
| `0x0009`–`0x000D` | `0x1800` | GAP (`0x000B` = Device Name) |
| `0x000E`–`0x0011` | `5CDE0C3D-7B1D-4352-94BB-02269C9F42B5` | **Notify service** |
| &nbsp;&nbsp;`0x0010` | `3337E46E-F79E-4FF5-9A49-77C36D170C62` | properties `0x10` = **notify only** |
| &nbsp;&nbsp;`0x0011` | `0x2902` | CCCD for the above |
| `0x0012`–`0x0014` | `53C47FE1-6C22-4EA6-99C7-7B6325EC75B9` | **Write service** |
| &nbsp;&nbsp;`0x0014` | `9C6AA1EE-B4B9-44A1-BA45-1558C9109B4C` | properties `0x0C` = **Write + Write Without Response** |
| `0x0015`–`0xFFFF` | `1D14D6EE-FD63-4FA1-BFA4-8F47B42119F0` | Silicon Labs **OTA** service |
| &nbsp;&nbsp;`0x0017` | `F7BF3564-FB6D-4E53-88A4-5E37E0326063` | properties `0x08` = Write. **Never write to this** (§11) |

**Notify and Write live in different services.** Do not assume they share one service.

The Included Service (`0x2802`) lookup returned an Error Response (Attribute Not Found)
all three times. There is no include.

### 2.1 Link-layer parameters (confirmed)

| Item | Value |
|---|---|
| Connection Interval | 30 ms |
| Connection Latency | 0 |
| Supervision Timeout | 720 ms (short — the link drops 0.72 s after power-off) |
| PHY | LE 2M on both TX/RX |
| Data Length Extension | 251 octets / 2120 µs on both TX/RX |
| **ATT MTU** | **247** (**the peripheral sends the Exchange MTU Request**; the iPhone responds with 247) |
| **SMP / bonding** | **None at all.** The link is not encrypted. Pairing happens entirely at the app layer (`0x4B`) |

MTU is 247, but frames top out at 11 bytes in practice. **Do not build anything that
depends on the MTU.**

---

## 3. Frame format

Identical for TX and TB (**confirmed**. Verified across all 23 frames, zero violations).

```
offset 0      : header  = 0xAA                    ← measured value for the AC6000BT
offset 1      : L       = total frame length (header/len/payload/checksum inclusive)
offset 2      : cmd
offset 3..L-2 : payload
offset L-1    : checksum
```

* **`L == the actual byte count`.** Matches in all 23 frames. Zero violating frames.
  Counted without `cmd` in the payload, **`L = payload.count + 4`**
  (header + L + cmd + payload + checksum). Same counting as the reference
  implementation in §3.3. Counted with `cmd` at the head of the payload, `L =
  payload.length + 3` — both mean the same thing.
* Multi-byte integers in the payload are **little-endian** (**confirmed**. §7 / §6.4).

### 3.1 Checksum — the keys are added in

```
checksum = ( Σ frame[0 .. L-2]  +  key1  +  key2 ) & 0xFF
```

**This is the single biggest finding in this capture.** A plain sum never matches for
any frame, but adding the two bytes carried in the advertisement (key1 / key2, §1.1)
makes every frame match.

* **Before** the key is established (i.e. the `0x4B` frame itself), `key1 = key2 = 0`.
* **After** the key is established, **both** TX and RX add `key1 + key2`.
* Verification: with the keyed formula, **23/23 frames match**.
  With a plain unkeyed sum, **22/22 frames mismatch**. Not a coincidence.

**Consequence: a client that doesn't know the key can neither build nor verify frames.**
This is also part of why `85 06 4b 00 00 d6` got no response in earlier hardware
tests (the header was also wrong).

### 3.2 Worked example

TX `READ_KEY` — before the key is established, so `key1 = key2 = 0`:

```
frame  : aa 06 4b c4 94 ??
sum    : 0xAA + 0x06 + 0x4B + 0xC4 + 0x94 = 0x253
+k1+k2 : 0x253 + 0x00 + 0x00              = 0x253
& 0xFF :                                    0x53
frame  : aa 06 4b c4 94 53          ✓ matches the capture
```

TX `READ_CURRENT_AMMO` — after the key is established (`key1 = 0xC4`, `key2 = 0x94`):

```
frame  : aa 05 5a 00 ??
sum    : 0xAA + 0x05 + 0x5A + 0x00 = 0x109
+k1+k2 : 0x109 + 0xC4 + 0x94       = 0x261
& 0xFF :                             0x61
frame  : aa 05 5a 00 61             ✓ matches the capture
```

RX `FIRE_REPORT` — the receiving side can be verified with the same formula:

```
frame  : aa 0a 52 00 00 1a 01 00 00 79
sum    : 0xAA+0x0A+0x52+0x00+0x00+0x1A+0x01+0x00+0x00 = 0x121
+k1+k2 : 0x121 + 0xC4 + 0x94                          = 0x279
& 0xFF :                                                0x79   ✓
```

### 3.3 Reference implementation (Swift)

```swift
/// key1/key2 are 0 before the 0x4B handshake, and the device's own keys after.
func aceChecksum(_ bytes: ArraySlice<UInt8>, key1: UInt8, key2: UInt8) -> UInt8 {
    var sum = Int(key1) + Int(key2)
    for b in bytes { sum &+= Int(b) }
    return UInt8(sum & 0xFF)
}

func aceFrame(cmd: UInt8, payload: [UInt8], key1: UInt8, key2: UInt8) -> [UInt8] {
    let body: [UInt8] = [0xAA, UInt8(payload.count + 4), cmd] + payload
    return body + [aceChecksum(body[...], key1: key1, key2: key2)]
}
// Note: cmd is the first byte of the payload in this counting, so
// L = (payload including cmd).count + 3. The formula above doesn't include cmd
// in `payload`, hence the +4.
```

### 3.4 ATT write type

Even though the write characteristic's properties include Write Without Response, the
app sends **all 8 frames as an ATT Write Request (with response)** (**confirmed**).
Our own client should also use `.withResponse`.

---

## 4. Init sequence (raw bytes)

`t` is elapsed seconds since LE Connection Complete. All from
`tools/re/notes/pklg-timeline.txt`.

### 4.1 GATT phase

| t | direction | contents |
|---|---|---|
| +0.030 | RX | Exchange MTU Request (Client Rx MTU 247) ← **from the device** |
| +0.391 | TX | Exchange MTU Response (Server Rx MTU 247) |
| +0.421…+1.260 | — | service / characteristic / descriptor discovery |
| +0.661 | TX | Write `0x0004` ← `02 00` (indication for `0x1801` Service Changed. iOS does this automatically) |
| **+1.263** | **TX** | **Write `0x0011` ← `01 00` (enables the CCCD on the notify characteristic)** |
| +1.320 | RX | Write Response |

### 4.2 Application phase

The first frame arrives **564 ms after** the CCCD response. After that, the command
queue flows at roughly **300–360 ms per frame** (wait for response → send next).

```
t=+1.827  TX  aa 06 4b c4 94 53              READ_KEY / VERIFY_KEY  (key1=0xC4, key2=0x94)
t=+1.890  RX  aa 05 41 4b 93                 ACK(0x41) for cmd 0x4B     ← 63 ms later
t=+2.205  TX  aa 05 5a 00 61                 READ_CURRENT_AMMO
t=+2.250  RX  aa 0a 5a 01 01 58 02 14 00 d6  current ammo = preset #1, 6.00 mm / 0.20 g
t=+2.554  TX  aa 05 62 00 69                 READ_LOG_COUNT
t=+2.610  RX  aa 06 62 00 01 6b              log count = 0 (see §6.5 — this is the confirmed reading)
t=+2.915  TX  aa 06 47 01 01 51              READ_AMMO_PRESET #1
t=+2.970  RX  aa 0b 47 00 41 01 58 02 14 00 04
t=+3.276  TX  aa 06 47 01 02 52              READ_AMMO_PRESET #2
t=+3.330  RX  aa 0b 47 00 41 02 58 02 19 00 0a
t=+3.635  TX  aa 06 47 01 03 53              READ_AMMO_PRESET #3
t=+3.690  RX  aa 0b 47 00 41 03 58 02 2b 00 1d
t=+3.995  TX  aa 06 47 01 04 54              READ_AMMO_PRESET #4
t=+4.050  RX  aa 0b 47 00 41 04 58 02 2d 00 20
t=+4.355  TX  aa 06 47 01 05 55              READ_AMMO_PRESET #5
t=+4.410  RX  aa 0b 47 00 41 05 58 02 58 00 4c
t=+5.627  TX  (ATT Read By Type 0x2A00) → "ACETECH-12345678"
```

**These 8 frames are everything the app sent.** No TX for the following 99 seconds.

### 4.3 Key handshake (`0x4B`) — confirmed behavior

In this capture, **the app already knew `key1=0xC4, key2=0x94`**. What was observed is
therefore a **VerifyKey** (checking a known key), not first-time pairing.

| Case | TX | RX |
|---|---|---|
| First time (key unknown) | `aa 06 4b 00 00 fb` | **unverified** (no response ever observed; reportedly needs the device's power button pressed) |
| **Subsequent (key known)** | **`aa 06 4b <k1> <k2> <cks>`** | **`aa 05 41 4b <cks>`** (cmd `0x41` = ACK, payload = the acknowledged cmd `0x4B`) |

**Confirmed facts:**

* The response arrives **63 ms later**. **No button press was needed**
  (an ACK comes back immediately once the key matches).
* The response cmd is **`0x41` (ACK), not `0x4B`**. Getting `0x4B` back with the key in
  the payload appears to be the **unknown-key** path; when the key is already known, the
  device takes this `0x41` ACK path instead.
* This ACK frame's own checksum **already includes `key1+key2`**. In other words, the
  device signals "the key matches" through the checksum itself, immediately.

**How to obtain the key: confirmed via advertisement manufacturer data offset 3/4
(§1.1) (2026-09-03).**

Verified against real hardware with our own client (`muzzlemeter-sniff dump --handshake`):

```
TX  aa 06 4b c4 94 53      ← the key taken straight from the advertisement (c4/94) is sent as-is
RX  aa 05 41 4b 93         ← ACK 55 ms later. No button press needed
```

**Consequence: as long as you can receive the advertisement, you can connect on the
first try with no button press.** As a fallback for the path where the advertisement is
missed (direct reconnection via `retrievePeripherals`), persist the established key per
device (implemented in `ChronoDevice.keysKey(for:)`).

---

## 5. Keep-alive / ping

**None observed (confirmed).**

* The app's last TX is at `t=+4.355`. **Zero writes** for the following 99 seconds.
* The device kept sending notifications during that time regardless
  (`t=+11.878` / `+49.948`…`+75.179`).
* → **The AC6000 MKIII BT needs no periodic ping.**

## 5.1 Disconnect sequence

**The app never initiates the disconnect (confirmed).**

```
t=+103.202  RX  00                      ← a 1-byte notification (ATT: 0x1b, handle 0x0010, value length 1)
t=+103.966      HCI Disconnection Complete, reason 0x08 = Connection Timeout
```

The link drops via supervision timeout (720 ms) 0.764 s after the `00`.

> **Correction to an earlier interpretation**: an earlier sniffer experiment observed the
> same "1 byte `00` → disconnect 0.77 s later" and interpreted it as a **NAK for a bad
> frame**. In this capture, the exact same `00` + 0.76 s → timeout happened **after a
> legitimate handshake succeeded and 5 shots were measured**. So this is **not a NAK — it
> is the device's power-off signature**. Our own client can treat a `00` as "the device
> just powered off."

---

## 6. Packet formats

### 6.1 RX packet inventory (every kind observed in this capture)

| cmd | name | L | count | example | meaning |
|---|---|---|---|---|---|
| `0x41` | ACK | 5 | 1 | `aa 05 41 4b 93` | payload = the acknowledged cmd. Here, `0x4B` |
| `0x47` | AMMO_PRESET | 11 | 6 | `aa 0b 47 00 41 01 58 02 14 00 04` | contents of an ammo preset slot (§6.3) |
| `0x52` | **FIRE_REPORT** | 10 | 5 | `aa 0a 52 00 00 1a 01 00 00 79` | one shot's measurement (§7) |
| `0x5A` | CURRENT_AMMO | 10 | 2 | `aa 0a 5a 01 01 58 02 14 00 d6` | currently selected ammo (§6.2) |
| `0x62` | LOG_COUNT | 6 | 1 | `aa 06 62 00 01 6b` | on-device log record count (§6.5) |
| `0x63` | LOG_RECORD | 9 | — | `aa 09 63 01 00 00 81 01 f1` | one log record (§6.6, confirmed 2026-09-03/04) |
| `0x4E` | NAK | 5 | — | `aa 05 4e ff 54` | rejection of an unknown command (§6.7, confirmed) |
| —  | (1 byte right before disconnect) | — | 1 | `00` | device power-off (§5.1) |

**Not observed in the original pklg capture** (still **unverified**):
`0x24` / `0x27` (device settings), `0x2C` / `0x64` (battery), `0x53`, `0x61`, `0x81`,
`0xD4`. In particular **no battery notification arrived in 104 seconds**. AceSoft either
gets battery through another path or doesn't use it on the AC6000.

### 6.2 `0x5A` READ_CURRENT_AMMO

```
TX : aa 05 5a 00 <cks>              payload = [0x5A, 0x00]     ; 0x00 = read
RX : aa 0a 5a 01 <slot> <ammo:4> <cks>
     aa 0a 5a 01 01  58 02 14 00  d6
              ^^ ^^  ^^^^^^^^^^^
              |  |   ammo record (§6.4)
              |  slot = currently selected preset number (1-based)
              payload[1] = 0x01 (meaning unclear; inferred to identify a read response)
```

The **same frame was resent unsolicited** at `t=+75.179` (no TX preceded it). Inferred
to be a device-side state-change notification (trigger unknown).

### 6.3 `0x47` READ_AMMO_PRESET

```
TX : aa 06 47 01 <idx> <cks>        payload = [0x47, 0x01, idx]   ; 0x01 = read preset
RX : aa 0b 47 00 41 <idx> <ammo:4> <cks>
     aa 0b 47 00 41 01  58 02 14 00  04
              ^^ ^^ ^^  ^^^^^^^^^^^
              |  |  |   ammo record (§6.4)
              |  |  echoed idx
              |  0x41 = ACK marker
              payload[1] = 0x00 (inferred: status = OK)
```

Observed `idx` values are **1..5**. The app reads all 5 slots in order.

The **idx=1 frame was resent unsolicited** at `t=+11.878` (no TX preceded it).

> **Real-hardware follow-up (2026-09-03)**: about 10 seconds after the handshake
> completed, `aa 0b 47 00 40 01 58 02 c8 00 b7` arrived even though we had sent nothing
> (the checksum is correct for keys c4/94).
> * payload[1] is **`0x40`** here (the capture had `0x41`). Inferred: **read response =
>   0x41 / unsolicited notification = 0x40** (**unverified**).
> * The weight field is **`0x00c8` = 200**. At ×100 that's 2.00 g, which doesn't
>   correspond to a real weight (at ×1000 it's 0.20 g). §6.4's scale is **still not
>   confirmed**.
>
> **Consequence: `0x47` arrives even when you didn't ask for it, roughly every 10
> seconds after connecting — treat it as a periodic/unsolicited status update, not an
> error.** Don't filter on the marker value — keep the raw bytes. The implementation
> exposes `AmmoRecord.rawDiameter` / `rawWeight` / `marker` for this reason.

The subcommand form `[0x47, 0x00]` never appeared in this capture; the meaning of
subcommand `0x00` is **unverified**.

### 6.4 Ammo record (4 bytes, two u16 LE) — **inferred**

```
offset 0..1 : u16 LE  diameter = mm × 100
offset 2..3 : u16 LE  weight   = g  × 100
```

| slot | bytes | u16[0] | u16[1] | interpretation |
|---|---|---|---|---|
| 1 | `58 02 14 00` | 600 | 20 | 6.00 mm / 0.20 g |
| 2 | `58 02 19 00` | 600 | 25 | 6.00 mm / 0.25 g |
| 3 | `58 02 2b 00` | 600 | 43 | 6.00 mm / 0.43 g |
| 4 | `58 02 2d 00` | 600 | 45 | 6.00 mm / 0.45 g |
| 5 | `58 02 58 00` | 600 | 88 | 6.00 mm / 0.88 g |

Rationale:

* `20 / 25 / 43 / 45 / 88` **exactly match real 6 mm BB weights (0.20/0.25/0.43/0.45/0.88
  g)**. At ×10 they'd be 2.0 g / 8.8 g, which don't exist. → **near-confirmed fixed-point
  at ×100**.
* The first field is `600` = 6.00 mm across every slot — the same ×100 scale.
* Whether the wire value changes when switching to a grain display is **unverified**.

### 6.5 `0x62` READ_LOG_COUNT — **confirmed against real hardware** (2026-09-03/04)

```
TX : aa 05 62 00 <cks>              payload = [0x62, 0x00]
RX : aa 06 62 <count> <0x01> <cks>  payload = [count, 0x01]
                ^^^^^  ^^^^
                |      constant 0x01. Meaning unknown — kept raw, never interpreted.
                count = number of records currently held. 0 when the log is empty.
```

Previously this section described the count/status byte order as undecided (LE16 vs.
`[status, count]`). It is now settled: **`payload[0]` is the record count**;
`payload[1]` is a fixed `0x01` whose meaning we don't know and don't try to interpret.

**The earlier decoder read the wrong byte** — it treated `payload[1]` as the count, so
an *empty* log (`aa 06 62 00 01 6b`) was misreported as `count = 1`. Two follow-up
sessions nail this down:

| capture | request → response | `payload[0]` (count) | context |
|---|---|---|---|
| `20260904-000817.log` | `aa 05 62 00 69` → `aa 06 62 00 01 6b` | **0** | right after a power cycle; log is empty |
| `20260904-000619.log` | `aa 05 62 00 69` → `aa 06 62 03 01 6e` | **3** | after firing 3 hand-thrown BBs; matches the 3 non-zero records read back via `0x63` |

**The on-device log is volatile**: power-cycling the device resets the count to 0 and
every record to all-zero. It only holds shots fired since the device was last powered
on. Records are stored in firing order (index 1 = oldest).

### 6.6 `0x63` READ_LOG_RECORD — **confirmed against real hardware** (2026-09-03/04)

Reads one log record after `0x62` reported the count. The request is a **single byte,
1-based index**; the response echoes that index and carries rev/speed:

```
TX : aa 05 63 <index> <cks>                         payload = [index]              (1 byte, 1-based)
RX : aa 09 63 <index> <rev0> <rev1> <speed0> <speed1> <cks>
              ^^^^^^^ ^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^
              echoed  rev  (u16 LE) speed (u16 LE)
              index   raw. Meaning  velocity = raw ÷ 100 → m/s
                      unconfirmed;
                      kept raw
                      (like FIRE_REPORT's
                      rawRev)
```

* **Index 0 gets no response at all.** The canonical request is exactly 1 byte; a
  trailing extra byte is accepted and ignored by the device (observed in
  `20260903-222919.log`: `aa 06 63 01 00 6c`, a 2-byte payload, got the same response as
  the 1-byte form).
* **An index beyond the reported count returns an all-zero record** (`rev = 0, speed =
  0`) — this is **not an error**, it simply means "nothing here." Because the log is
  volatile, records that were never written after the last power-on read back the same
  way.
* `rev` was `0x0000` in every observation so far (single, non-full-auto shots). It is
  presumed to be a rate-of-fire value in the same spirit as `FIRE_REPORT`'s `rawRev`, but
  its scale/unit is **unverified** — kept as a raw value, not converted.
* `speed ÷ 100` is the velocity in m/s, using the same fixed-point convention confirmed
  for `FIRE_REPORT` (§7.3).

**Real-hardware verification (2026-09-04, `20260904-000619.log`)**: three hand-thrown BBs
were fired, then read back via `0x62` → `0x63`:

| index | raw payload (after cmd) | rev | speed (raw) | speed ÷ 100 | device LCD history |
|---|---|---|---|---|---|
| 1 | `01 00 00 81 01` | 0 | 385 | **3.85 m/s** | 3.8 |
| 2 | `02 00 00 67 01` | 0 | 359 | **3.59 m/s** | 3.5 |
| 3 | `03 00 00 97 01` | 0 | 407 | **4.07 m/s** | 4.0 |
| 4 | `04 00 00 00 00` | 0 | 0 | — (all-zero: end of log, count was 3) | — |

The device's own LCD history (rounded to one decimal, truncated like §7.3) matches ÷100
in all three cases, confirming both the byte layout and the shared ×100 speed scale.

**How to capture more of these yourself**:

```sh
swift run muzzlemeter-sniff dump --name AC6000BT- --read-log
```

Lines starting with `read-log:` print the decoded record (or the raw payload, if it
doesn't parse). **Never send `0x61` (CLEAR_LOG)** (§11). No builder for it exists in this
codebase, so it cannot be sent by accident.

### 6.7 `0x4E` NAK — **confirmed against real hardware** (2026-09-03)

```
RX : aa 05 4e ff <cks>              payload = [0xFF]
```

Sending an unknown command (`0x50`, `0x51` were tried) gets back cmd `0x4E` ('N') with a
fixed payload `0xFF` — the rejection counterpart to ACK (`0x41`, 'A'). Unlike ACK, the
NAK payload does **not** echo which command was rejected.

```
TX  aa 04 50 56              (unknown cmd 0x50, no payload)
RX  aa 05 4e ff 54            NAK
TX  aa 05 50 00 57           (unknown cmd 0x50, payload [0x00])
RX  aa 05 4e ff 54            NAK
```

---

## 7. FIRE_REPORT (`0x52`)

### 7.1 Layout (**confirmed**)

L = 10 fixed, 7-byte payload.

```
offset  size  contents
  0      1    0xAA        header
  1      1    0x0A        L
  2      1    0x52        cmd = FIRE_REPORT
  3..4   2    u16 LE      always 0x0000 (meaning unclear; inferred: shot index / flags)
  5..6   2    u16 LE      rawSpeed          ★
  7..8   2    u16 LE      rawRev  (ROF)     ★  always 0 for single shots
  9      1    checksum
```

All 5 observed shots:

| t | hex | b[3..4] | **rawSpeed** | **rawRev** |
|---|---|---|---|---|
| +49.948 | `aa 0a 52 00 00 1a 01 00 00 79` | 0 | **282** | 0 |
| +55.378 | `aa 0a 52 00 00 fa 00 00 00 58` | 0 | **250** | 0 |
| +57.328 | `aa 0a 52 00 00 0b 01 00 00 6a` | 0 | **267** | 0 |
| +60.448 | `aa 0a 52 00 00 0a 01 00 00 69` | 0 | **266** | 0 |
| +63.509 | `aa 0a 52 00 00 31 01 00 00 90` | 0 | **305** | 0 |

* **No full-auto was recorded**, so `rawRev` is 0 for all 5 shots. Its scale
  (RPS / RPM / ×10) is **unverified**.

### 7.2 rawSpeed is "speed," not "transit-time count" (**confirmed**)

Hand-thrown (i.e. **slow**) BBs gave raw = 250..305. If raw were a light-gate transit-time
count, slower shots would give **larger** values, and a small value like ~250 wouldn't be
possible. If 250 were "transit time at low speed," a real airsoft/live shot (~100 m/s,
roughly 30× faster) would give raw ≈ 8, which breaks down as a resolution. →
**rawSpeed is proportional to speed and converts with simple scaling.**

### 7.3 Scale (**confirmed** — cross-checked against the device's own LCD)

```
speed_mps = rawSpeed / 100.0
```

> **Confirmed via a real-hardware follow-up (2026-09-03).** Three shots were fired and
> raw was cross-checked against the device's own LCD:
>
> | frame | rawSpeed | ÷100 | **device LCD** |
> |---|---|---|---|
> | `aa 0a 52 00 00 45 01 00 00 a4` | 325 | 3.25 | **3.2 m/s** |
> | `aa 0a 52 00 00 16 01 00 00 75` | 278 | 2.78 | **2.7 m/s** |
> | `aa 0a 52 00 00 77 01 00 00 d6` | 375 | 3.75 | **3.7 m/s** |
>
> * ÷100 is correct (the competing ÷10 hypothesis is **rejected** — it would be off by
>   10× on all three shots).
> * **The device's own LCD truncates to one decimal place rather than rounding**
>   (3.25 → 3.2, 3.75 → 3.7). The app's m/s display should match this truncation — a
>   mismatch between the device and the display would leave the user wondering which one
>   is "wrong." Internal values and the CSV export keep full precision
>   (`SpeedUnit.truncatesDisplay`).

| shot | raw | ÷100 → m/s | ÷10 → m/s | ÷10 → fps (= m/s) |
|---|---|---|---|---|
| 1 | 282 | **2.82** | 28.2 | 28.2 (8.60) |
| 2 | 250 | **2.50** | 25.0 | 25.0 (7.62) |
| 3 | 267 | **2.67** | 26.7 | 26.7 (8.14) |
| 4 | 266 | **2.66** | 26.6 | 26.6 (8.11) |
| 5 | 305 | **3.05** | 30.5 | 30.5 (9.30) |

Why `÷100 → m/s`:

1. **The same fixed-point-×100 convention is used elsewhere in this firmware.** The
   ammo record (§6.4) uses ×100 for both diameter (mm) and weight (g), and the weight
   values match real BB weights exactly — so ×100 is **independently confirmed** there.
2. **The unit is m/s (metric)**. Switching m/s ⇄ ft/s in the app produced **zero BLE
   traffic** (§8), so the wire value is unit-independent. Since the ammo record is
   metric regardless of the UI unit, speed is inferred to be metric too.
3. u16 × ÷100 tops out at 655.35 m/s (≈ 2150 fps), which covers the full airsoft/live-fire
   range — a sensible design.
4. User-reported context (hand-thrown BBs, "a few m/s") is consistent with 2.50–3.05 m/s.

**The competing `÷10 → m/s` hypothesis was rejected by the real-hardware follow-up
above** (all 3 shots matched the LCD under ÷100).

### 7.4 Reference implementation

```swift
struct FireReport {
    let rawSpeed: UInt16      // frame[5] | frame[6] << 8
    let rawRev: UInt16        // frame[7] | frame[8] << 8

    /// Scale confirmed against the device's own LCD (§7.3). The constant lives in one place only.
    static let speedScale: Double = 100.0
    var metersPerSecond: Double { Double(rawSpeed) / Self.speedScale }
}
```

---

## 8. Unit switching (m/s ⇄ ft/s)

**Display-only, inside the app. No BLE traffic (confirmed).**

The user switched units once during the capture, but from `t=+4.355` (the last TX) to
`t=+103.966` (disconnect), **there is not a single TX**. No settings write to the device,
and no resend from the device either.

→ The write layout for `0x24` WRITE_DEVICE_SETTINGS **could not be obtained from this
capture** (**unverified**).

→ Implementation approach: **do all speed/energy unit conversion client-side.**

---

## 9. RX checksum

**RX uses exactly the same formula as TX (confirmed).** §3.1.
Whether RX carries a checksum at all is settled.

A receiver should verify all of the following:

1. `frame[0] == 0xAA`
2. `frame[1] == frame.count`
3. `(Σ frame[0..count-2] + key1 + key2) & 0xFF == frame[count-1]`

A length-1 `00` fails all of 1–3. **Treat it as power-off, not an error** (§5.1).

---

## 10. Known unknowns / next things to confirm

| # | item | how to resolve |
|---|---|---|
| ~~1~~ | ~~rawSpeed scale~~ | ✅ **Resolved** (2026-09-03). ÷100 → m/s. LCD display truncates. §7.3 |
| 2 | `rawRev` scale / unit (RPS vs RPM) | Fire ~5 rounds full-auto. Compare measured firing interval (ms) against raw. **Unresolved** (implementation keeps the raw value) |
| 3 | Raw bytes for first-time pairing (unknown key) | Capture with a different phone/app reinstall. `aa 06 4b 00 00 fb` → button press → response |
| ~~4~~ | ~~Can the key be read from advertisement manufacturer data?~~ | ✅ **Resolved** (2026-09-03). Sending the advertisement's `c4 94` straight into `0x4B` got an **ACK in 55 ms**. **No button press needed**. §4.3 |
| 4b | **Ammo weight scale (×100 or ×1000)** | An unsolicited real-hardware `0x47` produced `0x00c8` = 200 (×100 would be 2.00 g, which doesn't exist). Vary the weight setting on the device and line up the raw values. §6.3 / §6.4 |
| ~~5~~ | ~~Is the `0x62` response's `00 01` a status+count pair or a BE16 count?~~ | ✅ **Resolved** (2026-09-03/04). `payload[0]` = count, `payload[1]` = constant `0x01` (meaning unknown). §6.5 |
| ~~6~~ | ~~`0x63` log record retrieval and format~~ | ✅ **Resolved** (2026-09-03/04). 1-byte, 1-based index request; response = `[index, rev0, rev1, speed0, speed1]`; speed ÷100 → m/s; all-zero = end of (volatile) log. §6.6 |
| 7 | Does battery (`0x2C` / `0x64`) work on the AC6000? | Send `aa 05 2c 00 <cks>` and see what comes back |
| 8 | `0x24` / `0x27` device settings layout | Send `aa 05 27 00 <cks>` and see what comes back |
| 9 | Trigger for the unsolicited `0x47` at `t=+11.878` / `0x5A` at `t=+75.179` | Correlate with button presses on the device |
| 10 | Meaning of FIRE_REPORT's `b[3..4]` (always 0) | Fire many rounds and see if it ever changes |
| 11 | Meaning of advertisement manufacturer data `08` / `52 04` | Compare against a different unit |

---

## 11. Safety

> ### 🚫 Never write to `F7BF3564-FB6D-4E53-88A4-5E37E0326063`
>
> Handle `0x0017`, in service `1D14D6EE-FD63-4FA1-BFA4-8F47B42119F0`, is the **Silicon
> Labs OTA (DFU) control**. Writing to it reboots the MCU **into the OTA bootloader**.
> Recovery requires a legitimate firmware image — **this can brick the device.**
>
> **AceSoft only enumerates it and never writes** (confirmed in this capture). Our own
> client and sniffer must also be **enumerate-only, write-forbidden** here. Restrict
> writes to a whitelist containing only `9C6AA1EE-B4B9-44A1-BA45-1558C9109B4C`.

> ### ⚠️ Don't send `0x61` CLEAR_LOG casually
>
> `0x61` appears to clear the device's measurement log. Now that log retrieval
> (`0x62` / `0x63`) is implemented and confirmed, there is still no reason to send it —
> this codebase has no builder for it at all, so it cannot be sent by accident. If you
> ever do an exploratory command sweep, **explicitly exclude `0x61`**.

> ### ⚠️ Don't brute-force unknown commands
>
> There are many opcodes not documented here. Some of them may correspond to
> calibration, competition locks, settings resets, or triggering the firmware loader.
> **Only send opcodes you have a specific, deliberate reason to try, one at a time,
> favoring reads.**

---

## 12. Implementation checklist

* [x] Scan matches the advertised name `AC6000BT-` by prefix (`0x2A00` is not used for identification)
* [x] Enable the CCCD (`01 00`) on notify `3337E46E-…` (service `5CDE0C3D-…`)
* [x] Write to `9C6AA1EE-…` (service `53C47FE1-…`) using **Write With Response**
* [x] Wait **~500 ms** between enabling the CCCD and the first write (the app waits 564 ms)
* [x] Send commands **one at a time**, waiting for the previous response, at **~300 ms** intervals
* [x] Persist `key1`/`key2` and add them into the checksum of every subsequent frame
* [x] Verify received frames on all 3 points: header / length / checksum
* [x] Treat a 1-byte `00` notification as "device powered off" (not an error)
* [x] Send **no** keep-alive (confirmed unnecessary)
* [x] Define the speed-scale constant in exactly one place (`FireReport.speedScale`. Confirmed in §7.3)
* [x] Display m/s **truncated** (to match the device's LCD. Internal values and the CSV keep full precision)
* [x] `0x47` / `0x5A` arrive unsolicited — don't filter on the marker value
* [x] Code-level ban on writing to the OTA characteristic
* [x] `0x62` reads `payload[0]` as the count (not `payload[1]`)
* [x] `0x63` requests use a 1-byte, 1-based index; an all-zero response ends the read, not an error
* [x] The on-device log is volatile — track "imported through index N" per device, and
      reset it to 0 when the reported count drops (power cycle), instead of relying on
      the raw count alone
