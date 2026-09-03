# Muzzlemeter

Muzzlemeter is an **unofficial** iOS companion app for the **Acetech AC6000 BT** airsoft
chronograph. It connects over Bluetooth LE, shows each shot's velocity and energy live,
and keeps a searchable history per gun profile. Built with SwiftUI, SwiftData and
CoreBluetooth. The BLE protocol is not published by the vendor, so it was worked out from
packet captures of my own device and verified against the unit's own LCD; the result is
documented in [`docs/PROTOCOL.md`](docs/PROTOCOL.md). Not affiliated with Acetech. MIT
licensed.

> **This app is unofficial and unaffiliated with Acetech. Acetech and AC6000 are
> trademarks of their respective owners.**

## Supported devices

| Device | Status |
|---|---|
| **AC6000 MKIII BT** | **Confirmed on real hardware** (verified against the unit's own LCD) |
| AC6000 BT | Should work (matched by a prefix match on the advertised name `AC6000BT-`; same frame format) |
| Other Acetech products (e.g. Bifrost) | **Not supported** (the protocol is very likely different) |

## Features

- Automatically connects to the device over BLE (remembers the last-connected unit and
  reconnects to it)
- Live display of each shot's velocity (m/s / fps) and energy (J)
- Session statistics: mean / max / min / SD / ES / rate of fire
- Gun profiles (manufacturer, model, power-source category, inner barrel length,
  regulation limit in J, default BB weight, etc.) and per-session variables (BB weight,
  gas type, hop setting)
- Records temperature, humidity, and pressure at the time of measurement, fetched once
  from WeatherKit (can also be overridden by hand)
- Browse, rename, and export history to CSV
- Session comparison (side-by-side stats for 2-3 sessions, overlaid velocity charts, a
  spread summary)
- Tagging, and filtering history by tag, gun, or free text
- Per-profile trends (a time series of mean velocity ± SD, and a scatter plot against
  temperature)
- Japanese / English (base language is Japanese)
- A replay mode that lets you review the UI without the physical device (plays back a
  real capture)
- Importing the log stored on the device itself (`0x62` / `0x63`, **confirmed on real
  hardware**. The log is volatile, so the app remembers how far it read into each
  device's log last time and reads only the difference)
- A macOS CLI for protocol analysis, `muzzlemeter-sniff` (BLE scanning / GATT
  enumeration / packet dumping)

## What it takes to talk to the AC6000 (essentials)

See `docs/PROTOCOL.md` for the full detail. Here's the minimum an implementer needs:

| | |
|---|---|
| Scan | prefix match on the advertised name `AC6000BT-`. **No service is advertised**, so scan with `services: nil` |
| notify | `3337E46E-F79E-4FF5-9A49-77C36D170C62` (service `5CDE0C3D-…`) |
| write | `9C6AA1EE-B4B9-44A1-BA45-1558C9109B4C` (service `53C47FE1-…`) **Write With Response** |
| Frame | `AA <L> <cmd> <payload…> <cks>`. `L` is the total frame length |
| Checksum | `(Σ frame[0..L-2] + key1 + key2) & 0xFF`. **You can neither build nor verify a frame without the key** |
| **Key** | **bytes 4 and 5 of the advertisement's manufacturer data** (`00 05 08 c4 94 52 04` → `key1=0xC4 key2=0x94`) |
| Handshake | TX `aa 06 4b <k1> <k2> <cks>` (signed with key 0/0, this one frame only) → RX `aa 05 41 4b <cks>` (ACK). **Returns in 55 ms. No button press needed on the device** |
| Keep-alive | **not needed** (don't send one) |
| Speed | `FIRE_REPORT (0x52)`'s `rawSpeed / 100` = m/s (confirmed against the device's own LCD). **The LCD truncates**, so the app's m/s display truncates the same way |
| Power off | a 1-byte `00` notification. Not an error. The link drops ~0.76 s later |
| Device log | `0x62` (count) / `0x63` (one record, 1-byte 1-based index). **Confirmed against real hardware.** The log is **volatile** — it resets to 0 records on power-cycle |
| 🚫 Forbidden | writing to the OTA characteristic `F7BF3564-…` (bricking risk). Sending `0x61` CLEAR_LOG |

The device also sends frames **you never asked for** (`0x47` / `0x5A` periodically,
roughly every 10 s after connecting). Don't treat "unexpected" as an error.

## Layout

| Path | Contents |
|---|---|
| `Sources/MuzzlemeterKit/` | Domain / protocol / BLE abstractions (a library shared by iOS and macOS) |
| `Sources/MuzzlemeterSniff/` | The macOS CLI: BLE scanning / GATT enumeration / packet dumping |
| `Tests/MuzzlemeterKitTests/` | Tests written with Swift Testing |
| `docs/PROTOCOL.md` | The reverse-engineering results (UUIDs, packet format, checksum) |
| `tools/re/` | The working directory for protocol research; capture log storage (gitignored) |
| `App/Muzzlemeter/` | The iOS app (SwiftUI + SwiftData) |
| `App/Muzzlemeter/Resources/Localizable.xcstrings` | The String Catalog for UI text. **Base language is ja**, en is a complete translation |
| `App/Info.plist` | A minimal base holding only `CFBundleLocalizations`; every other key is synthesized from build settings |
| `App/Muzzlemeter/Resources/<lang>.lproj/InfoPlist.strings` | ja / en purpose strings for permission prompts, substituting build-setting values at runtime |
| `App/Muzzlemeter.entitlements` | The WeatherKit entitlement (`CODE_SIGN_ENTITLEMENTS`) |
| `project.yml` | The XcodeGen definition that `.xcodeproj` is generated from |

## Using muzzlemeter-sniff

### Scan

Lists nearby BLE advertisements. Run it with the device powered on to check its name.

```sh
swift run muzzlemeter-sniff scan
swift run muzzlemeter-sniff scan --seconds 30
swift run muzzlemeter-sniff scan --filter-service ffe0
```

Example output (one device per line, deduplicated by identifier):

```
name: AC6000  id: 1A2B3C4D-...  rssi: -54  services: [FFE0]  mfg: 4c 00 12 ...
```

### Dump (connect and analyze)

Connects, enumerates every service / characteristic, reads each readable one once,
subscribes to every notify / indicate, and streams incoming packets as timestamped hex.
Ctrl-C to quit. Automatically tries to reconnect if disconnected.

```sh
swift run muzzlemeter-sniff dump --name AC6000
swift run muzzlemeter-sniff dump --id 1A2B3C4D-5E6F-...   # identifier from scan output
swift run muzzlemeter-sniff dump --name AC6000 --log tools/re/captures/single-shot.log
```

The format of a packet line:

```
[2026-09-02T22:31:04.512+09:00] [+412.7 ms] FFE1 len=8 hex: aa 55 01 5a ... ascii: .U.Z....
```

Unless given explicitly, the log is saved automatically to
`tools/re/captures/<yyyyMMdd-HHmmss>.log`.

### Handshake (`--handshake`) — use this for on-device verification

Extracts the key from the advertisement's manufacturer data and **automatically sends
`0x4B` READ_KEY once subscription completes**. The decoded meaning of each received frame
is shown on the line right after its hex dump.

```sh
swift run muzzlemeter-sniff dump --name AC6000BT- --handshake
```

Expected output:

```
見つかりました: name: AC6000BT-009809  ...  mfg: 00 05 08 c4 94 52 04
handshake: 広告から鍵を取得しました key1=0xc4 key2=0x94
[2026-09-03T...] write -> 9C6AA1EE-... (withResponse) len=6 hex: aa 06 4b c4 94 53
  -> READ_KEY key1=0xc4 key2=0x94
write 成功 9C6AA1EE-...
[2026-09-03T...] [+55.0 ms] 3337E46E-... len=5 hex: aa 05 41 4b 93 ascii: ..AK.
  -> ACK for READ_KEY                     ← success looks like this
```

Firing a BB from here decodes as a `FIRE_REPORT`:

```
[+...] 3337E46E-... len=10 hex: aa 0a 52 00 00 45 01 00 00 a4
  -> FIRE_REPORT rawSpeed=325 (3.25 m/s) rawRev=0 flags=0
```

`--handshake` and `--interactive` can be combined (to poke around further by hand after
the handshake):

```sh
swift run muzzlemeter-sniff dump --name AC6000BT- --handshake --interactive
```

Frame building and validation **reuse `MuzzlemeterKit`'s own `ChronoFrame` directly**, so
any byte sequence that gets through the sniffer will also get through the app.

### Pulling the device's internal log (`--read-log`) — **the `0x63` format is unverified**

The device accumulates measurement results internally. The record count (`0x62`) has
been confirmed by measurement, but **`0x63`, which reads records one at a time, has never
once been observed** — neither the shape of the request nor of the response
(`docs/PROTOCOL.md` §6.6). `--read-log` sends the guessed request (payload = the LE16
`index`) in index order and writes out **the raw response as-is**.

```sh
swift run muzzlemeter-sniff dump --name AC6000BT- --read-log
```

`--read-log` sends keyed frames, so it **automatically enables `--handshake`** (so no one
gets stuck wondering why nothing responds because they forgot the flag).

Expected output:

```
=== --read-log: 本体内ログを読み出します（0x62 → 0x63。0x61 は送りません） ===
[...] write -> 9C6AA1EE-... (withResponse) len=5 hex: aa 05 62 00 69
[...] 3337E46E-... len=6 hex: aa 06 62 00 01 6b
  -> LOG_COUNT count=1（status=0）
read-log: 本体内ログ 1 件
[...] write -> 9C6AA1EE-... (withResponse) len=6 hex: aa 06 63 00 00 6a
[...] 3337E46E-... len=10 hex: aa 0a 63 00 00 1a 01 00 00 8a
read-log: record 0/1 rawSpeed=282 (2.82 m/s) rawRev=0  payload: 00 00 1a 01 00 00

=== read-log: 採取した 0x63 の payload（1 行 = 1 レコード: <index> <hex>） ===
0 00 00 1a 01 00 00
=== ここまで。この部分をそのまま共有してください ===
```

**This output (or the log file) is exactly the material that will settle what `0x63`
actually is.** Any of the following outcomes would be useful:

- It reads as `record N/M rawSpeed=…` → matches the guessed layout, the same as
  `FIRE_REPORT`
- `未知の形式  payload: …` ("unknown format, payload: ...") → a different layout; work it
  out from the raw payload
- `0x63 index=0 に応答がありませんでした` ("no response to 0x63 index=0") → **the
  request shape is wrong**; try a different shape (e.g. `[0x01, index]`) with
  `--interactive`

> 🚫 **`0x61` (CLEAR_LOG) is never sent.** No builder for it exists at all, so it can't
> be sent unless someone hand-assembles the hex themselves (`docs/PROTOCOL.md` §11).

### Sending an initialization command

Used when the device requires a "start measurement" command (sends whatever byte
sequence you want to try, explicitly). Sent once subscription completes, with the result
shown. `--write` can be given multiple times.

```sh
swift run muzzlemeter-sniff dump --name AC6000 --write ffe1 01a50000 --write ffe1 02
swift run muzzlemeter-sniff dump --name AC6000 --write ffe1=01a50000   # "=" separator also works
```

When `--write` is given multiple times, they're sent one at a time, **200 ms apart** by
default — so a response can be matched to the write that caused it. The interval can be
changed with `--write-delay <ms>` (`0` sends them back-to-back).

```sh
swift run muzzlemeter-sniff dump --name AC6000 --write ffe1 01 --write ffe1 02 --write-delay 500
```

#### Write type (`--write-type`)

A BLE write can be **withResponse** (the peer returns an ATT response) or
**withoutResponse** (fire-and-forget). Which one a device accepts depends on its
firmware — some only process one of the two, and some declare one property but actually
behave differently. Because of that, the type can be chosen explicitly.

| Value | Behavior |
|---|---|
| `auto` (default) | withResponse if the `write` property is present, otherwise withoutResponse |
| `with` | **Always withResponse**, regardless of the property |
| `without` | **Always withoutResponse**, regardless of the property |

`with` / `without` force the write even to a characteristic that doesn't declare the
property (with a warning line). The whole point of this option is being able to try a
peer whose declared properties can't be trusted.

```sh
swift run muzzlemeter-sniff dump --name AC6000 --write-type without --write ffe1 850600
```

`--write-type` becomes the **default** for `--write` and for `<hex>` / `w` in interactive
mode. In interactive mode it can be overridden per-command with `wr` / `wn`.

### Interactive mode (for handshake trial and error)

Adding `--interactive` (short form `-i`) makes it **read commands from stdin one line at
a time** once GATT enumeration, subscription, and any `--write`s have finished. This
removes the need to reconnect for every byte sequence you want to try, so it's the tool
of choice when brute-forcing an unknown handshake.

```sh
swift run muzzlemeter-sniff dump --name AC6000 --interactive
swift run muzzlemeter-sniff dump --name AC6000 -i --write ffe1 01a50000   # initialize, then interact
swift run muzzlemeter-sniff dump --name AC6000 -i --write-type without    # default to without
```

Accepted commands:

| Input | Action |
|---|---|
| `5a 4b 00 4b` / `5a4b004b` | Send to the **default write characteristic** (type follows `--write-type`) |
| `w <char> <hex>` | Write to a specified characteristic (type follows `--write-type`) |
| `wr [<char>] <hex>` | Write **with response** |
| `wn [<char>] <hex>` | Write **without response** |
| `r <char>` | Read a characteristic |
| `sub <char>` / `unsub <char>` | Subscribe to / unsubscribe from notify |
| `mtu` | Show the max bytes sendable in one write |
| `list` | Redisplay the GATT tree (with `*notifying*` markers) |
| `h` | Help |
| `q` / Ctrl-D | Disconnect and quit |

- `<char>` can be a characteristic UUID (a short form like `ffe1` also works), or a
  **prefix match that resolves uniquely**. If it matches more than one, the candidates
  are printed and nothing is sent.
- The **default write characteristic** is the first characteristic with write (with
  response); if none, the first with writeWithoutResponse. It's shown at startup
  together with the default write type.
- `<char>` can be omitted for `wr` / `wn`. It's interpreted as a characteristic only when
  **there are 2 or more tokens and the first one is 4, 8, or 36 digits long**. In
  `wn 85 06 4b`, `85` is only 2 digits, so it stays hex. To send 4-digit-grouped hex to
  the default target, join it into one token: `wn 85064b00`.
- **Multiple frames can be written on one line, separated by `;`**. They're sent in order
  spaced `--write-delay` apart, so a sequence that needs to be sent back-to-back (like a
  handshake) can be tried on a single line:

  ```
  > 85 06 4b 00 00 d6 ; 85 05 5a 00 e4
  > wn 8506 ; wr ffe1 5a00 ; r ffe1
  ```

  If even one segment can't be parsed, **nothing is sent at all** (to prevent a typo from
  sending only the first half).
- Blank lines and lines starting with `#` are ignored. Unparseable input prints a
  one-line usage message.
- Every write / read / result during the session **is recorded in the capture log too**,
  so it can be replayed later with `ReplayScript`.

`maximumWriteValueLength`, shown by `mtu` (and automatically right after connecting), is
useful for telling apart "the frame is too long and getting cut off" from "it's not
arriving at all." withoutResponse is typically the negotiated ATT_MTU minus 3 bytes;
withResponse is usually reported as up to 512, since it's split into multiple packets.

```
最大 write 長: withResponse=512 bytes  withoutResponse=182 bytes
```

Since notify keeps streaming in asynchronously even while typing, the `> ` prompt is only
shown **right after startup and right after each command's result** (showing it every
time would flood the screen with packets).

Candidate byte sequences can also be piped or redirected in from a file. **When reading
from something other than a terminal, lines are processed one at a time, `--write-delay`
apart**, so it's still clear which response belongs to which line:

```sh
printf '5a4b004b\n5a4b014c\n' | swift run muzzlemeter-sniff dump --name AC6000 -i
swift run muzzlemeter-sniff dump --name AC6000 -i --write-delay 500 < candidates.txt
```

### macOS Bluetooth permission

Using CoreBluetooth from the CLI requires Bluetooth permission for **the terminal app
itself**. A permission dialog appears the first time it runs. If it doesn't appear, or
you accidentally denied it, go to

**System Settings > Privacy & Security > Bluetooth**

turn on Terminal.app (or iTerm.app, or whichever app you're running it from), and
**restart that app** before running it again.

Important notes:

- Permission is evaluated against **the parent app that launched the process (the
  responsible process)**, not `muzzlemeter-sniff` itself. Launching it from an editor's
  or another tool's integrated terminal means that app lacks permission, and macOS kills
  the process outright with **SIGABRT** (in that case, a message explaining why is
  printed to stderr before exiting). **Run it directly from Terminal.app / iTerm.app.**
- The CLI executable embeds an Info.plist containing `NSBluetoothAlwaysUsageDescription`
  in its `__TEXT,__info_plist` section (via `Package.swift`'s linker settings and
  `Sources/MuzzlemeterSniff/Info.plist`). Without it, CoreBluetooth initialization always
  crashes.
- If Bluetooth is off, or permission has been denied, this prints that fact and exits
  with status code 1.

## Build

### MuzzlemeterKit and the CLI

**Works with just the Command Line Tools toolchain (Swift 6.4).**

```sh
swift build
swift test
```

### The iOS app

`.xcodeproj` is a **build artifact generated from `project.yml` via XcodeGen**, and is
not included in the repository (gitignored). **Always run this first** after cloning, or
after changing `project.yml` or the file layout:

```sh
xcodegen generate          # -> Muzzlemeter.xcodeproj
```

**Building the iOS app requires Xcode 26 or later** (with the Xcode 16 series, macro
expansion for `@Observable` requires `!=` and fails to build on SwiftData `@Model`
types). The Command Line Tools toolchain is enough for `MuzzlemeterKit` /
`muzzlemeter-sniff` alone.

After that:

```sh
open Muzzlemeter.xcodeproj
# or
xcodebuild -project Muzzlemeter.xcodeproj -scheme Muzzlemeter \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Using `xcodebuild` requires Xcode's own toolchain to be selected (**a one-time step you
do yourself**, requires your password):

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

This is **not needed** for the CLI's `swift build` / `swift test`.

#### Signing (DEVELOPMENT_TEAM)

`project.yml`'s `DEVELOPMENT_TEAM` has the author's own Team ID hardcoded (so it doesn't
need to be re-entered in Xcode after every `xcodegen generate`). **If you fork this and
run it on real hardware, change it to your own Team ID.** For the simulator no signing
is needed — add `CODE_SIGNING_ALLOWED=NO` and it builds as-is.

Since the app uses WeatherKit, building for real hardware requires an **App ID with
WeatherKit enabled**. If you don't need it, remove
`com.apple.developer.weatherkit` from `App/Muzzlemeter.entitlements` (environmental data
will just be empty; measurement itself is unaffected).

#### If the repo lives under iCloud Drive (Desktop)

When the repository sits in a folder synced by iCloud, sync conflict copies (duplicate
files like `Foo 2.swift`) can end up in the build directory, and SwiftPM's build fails
with `filename "..." used twice`. **Moving intermediate build products outside the
synced folder** fixes this:

```sh
swift build --scratch-path /tmp/muzzlemeter-build
swift test  --scratch-path /tmp/muzzlemeter-build
xcodebuild -project Muzzlemeter.xcodeproj -scheme Muzzlemeter \
  -derivedDataPath /tmp/muzzlemeter-dd \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### Real-hardware mode and replay mode

| Environment | Transport |
|---|---|
| Real iPhone | `CoreBluetoothTransport` (actually connects to the AC6000) |
| Simulator | `ReplayTransport` (automatic, since there's no CoreBluetooth hardware) |
| Real hardware + `--replay` | `ReplayTransport` |

**The decoder and configuration are the same in both cases**
(`MuzzlemeterDecoder` + `ChronoDevice.Configuration.ac6000()`). Replay goes through the
same key-handshake path as real hardware, so behavior looks identical from the UI's
perspective (`ReplayTransport.demoPeripheral` carries the real device's own advertisement
`00 05 08 c4 94 52 04`).

There are two replay sources:

- Default (`--replay`): a synthesized script in
  `App/Muzzlemeter/Services/ReplaySupport.swift`. Has many shots, making it easy to build
  out the UI. **The byte sequences are built using the real protocol.**
- `--replay-capture`: fast-forward playback of
  `App/Muzzlemeter/Resources/acesoft-iphone-rx.txt` (an actual capture from the official
  app itself, including 5 shots and the power-off)

`ReplayScript` can **also read the log format produced by `muzzlemeter-sniff dump`
directly**, so a freshly captured log can be dropped in and replayed as-is.

#### Launch arguments for visual verification (Debug builds on the simulator only)

Things like the regulation-limit color coding or N-shot mode are only visible when
"specific values happen to be present." So that this state can be produced without
manually operating the simulator, `ScreenshotSupport` interprets the following arguments
**only on Debug builds running in the simulator** (a release build never even parses
these arguments, so they have no effect on the shipped behavior):

```sh
xcrun simctl launch <udid> com.yhakamay.muzzlemeter --replay-capture \
  --demo-energy-limit 0.001 \   # override the selected profile's regulation limit (J)
  --demo-target-shots 5 \       # override the target shot count (0 reverts to manual)
  --demo-tab settings \         # the tab shown at launch (live / sessions / settings)
  --demo-scan-sheet \           # open the device selection sheet right at launch
  --demo-latest-session \       # open the latest session's detail in the history tab
  --demo-seed-sessions \        # seed 5 sample sessions (only when the store is empty)
  --demo-compare \              # open the comparison screen for the last 3 sessions in the history tab
  --demo-tag-editor \           # open a sample session's detail and its tag editor sheet
  --demo-filter 屋内 \          # apply a tag filter to the history tab
  --demo-profile-detail \        # open the first profile's detail in the settings tab
  --demo-device-log 12 \         # make the mock device report "12 records in its internal log"
  --demo-device-log-broken 4 \   # return the 5th of those records in an unsupported format
  --demo-device-log-auto         # start the import without tapping the banner (for visually checking progress/results)
```

`--demo-seed-sessions` exists for screens that **only appear once multiple sessions have
accumulated**, like comparison, tags, and trends. It does nothing if sessions already
exist.

`--demo-device-log` exists for importing the device's internal log. The mock device (the
`ReplayTransport` responder) answers `0x62` / `0x63`, so **the app side goes through the
same path as real hardware** (write -> notify -> decode). It holds 1 record by default
(matched to the count that `0x62` answered with in the real capture).
Adding `--demo-device-log-broken <n>` makes only the nth record come back unreadable, so
the "unsupported format — the log was saved" message and the raw-data export can be
checked visually. `--demo-device-log-auto` exists to show the screen right after tapping
"import" (progress and results). Since a real-capture replay stays connected for **less
than 10 seconds**, tapping it by hand and catching the progress in time is a matter of
luck. With this flag, the import starts automatically as soon as the count is known.

> ⚠️ What the mock device returns for `0x63` is a **guess**
> (`docs/PROTOCOL.md` §6.6). Once the real-hardware format is known,
> `ReplayTransport.deviceLogResponder` will be replaced along with it.

### Environment (temperature, humidity, pressure)

On the first shot of a session, the current conditions are fetched once from WeatherKit
and CoreLocation and recorded on the `Session` (`SessionEnvironmentService`). The fetch
runs as a detached task, so **measurement is never blocked at all**; if it fails, the
automatic value is simply left empty. The values can be overridden by hand from the
detail screen's "Environment" section, and the effective value is `manual ?? auto`.

**The WeatherKit entitlement doesn't work in the simulator, so no value can be fetched
there.** So the UI can still be checked visually, `SessionEnvironmentService` has a path
that returns sample values, but only when running `--replay-capture` in the simulator
(`#if targetEnvironment(simulator)`). It never runs on the real-hardware code path.

## Verifying against real hardware

1. Power on the device and place it near the Mac
2. **From Terminal.app / iTerm.app** (an integrated terminal from another app won't
   work):

   ```sh
   swift run muzzlemeter-sniff dump --name AC6000BT- --handshake
   ```

3. If `-> ACK for READ_KEY` appears, the handshake succeeded. Fire a BB and compare the
   `FIRE_REPORT rawSpeed=…` line against **the device's own LCD**
4. The log is kept at `tools/re/captures/<date-time>.log`, ready to use directly in
   `Tests/MuzzlemeterKitTests/Fixtures/` or a replay script

Things still unverified (`docs/PROTOCOL.md` §10):

- The unit of `rawRev` (rate of fire) — fire several rounds full-auto and compare against
  the interval between shots
- The wire scale for BB weight (×100 or ×1000) — watch `0x47` while changing the weight
  setting on the device
- The first-pairing path when the key is unknown (implemented, but never observed against
  a real device)
- **The request/response shape for `0x63` (one device-log record)** — see the output of
  `swift run muzzlemeter-sniff dump --name AC6000BT- --read-log`

## Protocol

Since the BLE spec isn't published by the manufacturer, it was worked out **by measuring
communication with my own unit**.

- Results: [`docs/PROTOCOL.md`](docs/PROTOCOL.md) (UUIDs, frame format, checksum, key
  handshake, opcode table)
- Only two sources were used:
  1. HCI logs captured on my own iPhone (a `.pklg` from Apple's PacketLogger)
  2. On-device testing with the custom client `muzzlemeter-sniff`
- See [`tools/re/README.md`](tools/re/README.md) for how the research was carried out

`docs/PROTOCOL.md` documents only **observed facts**, each labeled with its confidence
(confirmed / presumed / unverified). What's still unfilled is collected in §10.

## Privacy

- **Bluetooth** is used only to talk to the chronograph. It never connects to any other
  device.
- **Location** is fetched once, on a session's first shot, solely to look up
  temperature/humidity/pressure at that spot via **WeatherKit**. The location itself is
  never stored.
- Measurement data is stored **only in the on-device SwiftData store**. CSV export only
  runs when the user explicitly triggers it.
- **No analytics or tracking SDK is included, at all.**
- **No network traffic occurs other than WeatherKit.**

## Disclaimer

- This app is an unofficial app **unaffiliated with Acetech**, and is not approved,
  supported, or warranted by the manufacturer. **Acetech**, **AC6000**, and **AceSoft**
  are trademarks of their respective owners.
- This app is **not a tool for determining legal or regulatory compliance**. The
  displayed velocity and energy are reference values converted directly from the
  chronograph's own output, and are subject to measurement error, BB-to-BB variance, and
  configuration mistakes. **Confirming that muzzle velocity or energy does not exceed the
  limits set by law or field rules is the user's own responsibility**, to be done through
  officially recognized methods.
- This software is provided **with no warranty**, as stated by the MIT license. Writes to
  the device are restricted to read-only operations, but the author accepts no
  responsibility for any damage, including device failure or data loss.

## Contributing

Issues and pull requests are welcome. Reports on **whether it works on an AC6000 BT
(non-MKIII)** are especially appreciated, along with captures that resolve any of the
unverified items in `docs/PROTOCOL.md` §10.

- Commit messages must carry an **ADR** (Context / Decision / Alternatives considered /
  Consequences) in the body, for any commit that involves a design choice, so it can be
  traced later. See [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md)
  for details.
- Run `swift test` before opening a PR, and if the change needs `xcodegen generate`, edit
  `project.yml` accordingly (`.xcodeproj` itself is never committed).
- **Information obtained by decompiling someone else's app is not accepted.** Only
  observed facts obtained from your own communication captures and on-device testing may
  be added to `docs/PROTOCOL.md`.
- PRs that add dangerous operations (writing to the OTA characteristic, `0x61`
  CLEAR_LOG) will not be accepted. See `docs/PROTOCOL.md` §11.

## License

[MIT](LICENSE) © 2026 Yusuke Hakamaya
