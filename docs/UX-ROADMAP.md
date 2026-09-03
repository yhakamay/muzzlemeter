# UX Roadmap (agreed with the user on 2026-09-03)

## Splitting the data model (Round A, shipped)

| Where it lives | Fields |
|---|---|
| Profile (the gun itself) | Name / manufacturer / model / power-source category (electric, gas, spring, HPA) / inner barrel length / regulation limit in J (default 0.98, editable) / notes / default session variables (BB weight, gas type, hop setting) |
| Session (this round's conditions) | BB weight / gas type (only when the category is gas) / hop setting / tags / notes / name / environmental data (automatic + manual override) |

- A session auto-starts on the first shot, seeded from the profile's defaults (no
  blocking UI).
- Right under the profile pill on the Live screen, a line like "0.25 g · HFC134a ·
  hop 3" is shown; tapping it changes the session variables. The change applies to the
  whole session (joules are recalculated).
- The existing `GunProfile.powerSource` (which bundled in gas type) is split into
  "category" and "gas type," migrating existing data.

Implementation notes (see the ADR on the relevant commit for detail):

- Session variables are the value type `SessionVariables` (BB weight, gas type, hop).
  The profile holds only their **defaults**, and a session snapshots them at start.
- The "conditions the next session will start with" while idle live in
  `ChronoService.pendingVariables` (not persisted).
- Migration is done by adding columns plus deriving values at launch
  (`StoreMigration`). `VersionedSchema` isn't used.
- `bbWeightGrams` / `hopNotes` keep their column names, referred to under the aliases
  `defaultBBWeightGrams` / `defaultHopSetting`.
- CSV: `power_source` -> `power_category`; `gas_type` / `hop_setting` /
  `energy_limit_j` added.

## Round B: around Live
1. ✅ Regulation-limit line (color-coded margin/caution/exceeded against the profile
   limit, with haptics + sound when exceeded)
2. ✅ Warning when the device's own Ammo setting (0x47) mismatches the profile's BB
   weight
3. ✅ Read-aloud of each shot's velocity (on/off)
5. ✅ "N-shot mode": automatically closes the session once the target shot count is
   reached
11. ✅ Shows the device names and RSSI found while scanning (to avoid mixing up multiple
   units)

Implementation notes (see the ADR on the relevant commit for detail):

- **1. Regulation-limit line**: the judgment lives in `MuzzlemeterKit.EnergyLimit`
  (`margin(joules:limitJoules:)`). 90% or less of the limit = margin / over 90% up to
  under the limit = caution / **exactly at the limit or over = exceeded** (erring on the
  safe side). The color is decided in one place, `EnergyMargin.tint`, and the same color
  is used by the Live screen's large number, the recent-shots list, and the history
  list/chart. Sound and vibration live in `FeedbackService` (split out from
  `ChronoService`; sound follows `AVAudioSession`'s `.ambient` category, i.e. respects
  the silent switch). "Margin" is judged against **the single highest shot in that
  session** (an average would hide an outlier).
- **2. Ammo mismatch**: `AmmoRecord.weightGrams` was made optional, reading a raw value
  of 100 or more as ×1000 and under 100 as ×100 (accepting both of the two scales
  described in `docs/PROTOCOL.md` §6.4). A value that would be an unreal weight either
  way becomes `nil`. `0x5A` is always taken as "the currently selected BB," while `0x47`
  is only taken as such for a spontaneous notification (marker 0x40). If the difference
  exceeds 0.005 g, a banner appears under the connection pill with two choices: "set
  the session to 0.20 g" or "ignore." **Nothing is ever written back to the device.**
- **3. Read-aloud**: `AVSpeechSynthesizer`. The spoken text goes through the same
  formatting as the display (a displayed 92.5 is read the same way the digits would be
  spoken in Japanese). The audio session deliberately treats notification sound and
  speech differently: notification sound is `.ambient` (respects the silent switch),
  while speech is `.playback` + `.duckOthers` (**does not** respect it) — the reasoning
  is written in the setting's own description text. During full-auto, an in-progress
  utterance is cut off so only the latest shot gets spoken.
- **5. N-shot mode**: judged via `ShotTarget` (part of the kit; `nil`/0/negative doesn't
  count as a target). **Closes on reaching the target exactly, or overshooting it**
  (since full-auto can overshoot). The target shot count lives in `SessionVariables`
  (the profile provides the default, a session can override it). Closing happens
  **after saving**. The summary is shown as an overlay, with "again" continuing under
  the same conditions and "close" clearing the target shot count — the difference
  between the two buttons is spelled out in their description text.
- **11. Scan display**: added `DiscoveryList` to the kit (sorts last-connected-first,
  then by signal strength) and `DiscoveredPeripheral.signalBars` (RSSI -> 0-4 bars),
  delivered via `ChronoEvent.discovered` **only when something changed**. CoreBluetooth
  scanning was switched to `allowDuplicates: true` in order to track RSSI. Tapping the
  connection pill opens a sheet to reconnect to a different chosen device.
  Auto-connect wasn't removed — this was added as **an entry point for overriding it**.

## Round C: analysis
6. ✅ Session comparison (side-by-side stats for 2-3 sessions + an overlaid chart)
7. ✅ Tagging and filtering
9. ✅ A time series of mean velocity and a scatter plot against temperature, on the
   profile detail screen

Implementation notes (see the ADR on the relevant commit for detail):

- **6. Session comparison**: there are two entry points — selection mode in the history
  list, and "Compare with other sessions" from a session's detail — both of which
  collapse into the same **value**, `SessionComparisonRequest` (2-3 sessions), and lead
  to the same destination. Which value in the table is "better" is decided by
  `MuzzlemeterKit.ComparisonTable`, which marks **only the metrics that have a
  direction** (SD, ES, shots over the limit) — marking a mean or a max would mislead the
  reader into thinking "the marked one is better." Marks use a pale background plus bold
  text rather than color, so as not to collide with the regulation limit's orange/red.
  Series colors are blue/purple/teal for the same reason (avoiding orange and red). The
  stats are computed once, when the view opens, and held in `SessionComparisonEntry`.
- **7. Tags**: still saved into the existing `Session.tagsRaw` (a single
  newline-separated column). Normalization, dedup, equality, and filtering were all
  collected into `MuzzlemeterKit.SessionTags` / `SessionFilter` (so the save path and
  the filter path never disagree about "the same tag"). Equality **ignores case and
  full-width/half-width forms, but not dakuten** (voicing marks) — dakuten changes the
  meaning of a word in Japanese. Filtering is applied to an already-fetched array rather
  than a SwiftData predicate. Tags are ANDed; text search is an OR across title, notes,
  and tags. Pinning the filter banner to the top clashed visually with the large title
  and made "History" disappear, so only the History screen was switched to an inline
  title. A `tags` column (semicolon-separated) was added to the CSV export.
- **9. Profile trends**: tapping a profile row in Settings now navigates to a **detail
  screen** rather than the edit sheet (editing moved to "Edit" within the detail). It
  can also be opened as a sheet from Live's profile menu via "Profile details" (so it
  doesn't push the measurement screen aside mid-session). The time series, scatter plot,
  and summary are computed by `MuzzlemeterKit.ProfileTrend`. The overall SD is **not**
  the average of each session's own SD — it's the sample SD treating every shot as one
  combined sample (via the decomposition
  `(N-1)*s^2 = sum((n_i-1)*s_i^2) + sum(n_i*(m_i-M)^2)`). The scatter plot only includes
  sessions with a recorded temperature, and shows a disclaimer below 3 points ("not
  enough to read a trend from"). Sessions are matched to a profile by **the gun name
  recorded on the session** (to preserve the design where a session never references a
  profile directly — renaming a profile means past sessions under the old name stop
  showing up).

## Round D (shipped): importing the device's internal log (0x62 record count / 0x63
readout; 0x61 erase is not implemented)

## Round E: extended targets
4. ✅ Live Activity (Dynamic Island / lock screen)
10. ✅ Home Screen widget
12. ✅ Apple Watch velocity display

Implementation notes (see the ADR in each commit for the full reasoning):

- **4. Live Activity**: added a `MuzzlemeterWidgets` WidgetKit extension target
  (`project.yml`). What to show and when to update is pure logic in
  `MuzzlemeterKit.LiveActivityContent` (`derive(shots:massGrams:speedUnit:...)`)
  and `LiveActivityUpdateThrottle` (throttles to at most 1 update/s so full-auto
  bursts don't spam `ActivityKit`), both unit tested. `ActivityAttributes` itself
  can't live in the kit (`ActivityKit` isn't available on macOS, which the kit
  also targets for the sniffer CLI), so `MuzzlemeterLiveActivityAttributes` and
  the actual lock-screen / Dynamic Island `View`s live in `App/Shared`, compiled
  into both the app and the widget extension so they render identically.
  `ChronoService` starts the activity on the first shot, updates it (through the
  throttle) on every shot, and ends it with the final state on session end or
  discard. Since the simulator has no way to lock the screen or open Dynamic
  Island from a script, `LiveActivityPreviewHost` (behind `--demo-widgets`)
  renders the exact same shared `View`s inside the running app for visual
  verification instead of a separate reimplementation.
- **10. Home Screen widget**: added `SessionSummaryWidget` (small + medium) to
  the same `MuzzlemeterWidgets` extension. It does **not** open the app's
  SwiftData store from the extension process — `MuzzlemeterKit.HomeWidgetSnapshot`
  is a small, pure, `Codable` summary of the most recently *ended* session
  (title, gun, shot count, mean velocity, mean joules, over-limit count),
  written by `HomeWidgetSnapshotWriter` to an App Group–shared `UserDefaults`
  suite (`HomeWidgetSnapshotStore`, unit tested) whenever `ChronoService.endSession()`
  runs, then `WidgetCenter.reloadTimelines(ofKind:)` tells the widget to redraw.
  A **discarded** session intentionally does not write a snapshot, so a batch
  of misfires never becomes the "latest session" shown on the Home Screen.
  Sharing the whole SwiftData container across the App Group was considered
  and rejected: the extension would have to track every future `Session`
  schema change even though it only ever shows a handful of numbers, and a
  concurrent write from the app while the extension reads could corrupt the
  store. `SessionSummaryWidgetView` and friends live in `App/Shared` next to
  the Live Activity views, for the same reason (and so `LiveActivityPreviewHost`
  can preview them too) — `WidgetFamilyKind` is a tiny extension-independent
  stand-in for `WidgetKit.WidgetFamily` so that shared file doesn't need to
  import `WidgetKit` from the app target.
- **12. Apple Watch velocity display**: added `MuzzlemeterWatch`, a standalone
  watchOS 10 SwiftUI app target (companion to the iPhone app via
  `WKCompanionAppBundleIdentifier`, not independently installable). **The
  phone stays the BLE central; the watch never talks to the AC6000
  directly** — `docs/PROTOCOL.md`'s handshake and framing only exist in
  `ChronoDevice`/`CoreBluetoothTransport` on iOS, and duplicating that on
  watchOS would mean two BLE stacks racing to connect to the same
  chronograph. Instead `ChronoService` relays state to the watch over
  `WatchConnectivity` through two paths, chosen for different reliability
  needs: `WCSession.sendMessage` for a fast, low-latency push on every shot
  (throttled with the same `LiveActivityUpdateThrottle` used for the Live
  Activity, since full-auto would otherwise flood the channel), which only
  arrives while the watch app is reachable in the foreground; and
  `updateApplicationContext` at session start/end/discard, which the system
  retains and redelivers the next time the watch app launches — this is
  what makes the watch "robust to being closed" rather than just showing
  stale data. What to send is `MuzzlemeterKit.WatchLiveState` (derived from
  shots the same way `LiveActivityContent` is) and the smaller
  `WatchShotMessage` for the per-shot push; `WatchPayloadCoding` is a tiny
  helper that encodes/decodes those into the `[String: Any]` dictionaries
  `WCSession` expects, without the kit importing `WatchConnectivity` itself
  (unavailable on macOS, which the kit also targets). Added `.watchOS(.v10)`
  to `Package.swift`'s platform list so the watch app can link
  `MuzzlemeterKit` directly and reuse `JouleFormat`/`SpeedUnit`/`EnergyMargin`
  for identical formatting; `MuzzlemeterSniff` (the macOS-only sniffer CLI)
  is unaffected. A WidgetKit complication was **skipped** for this round —
  the watch app itself was the higher-value target given the time
  available, and a complication can be added later as its own small
  extension without touching this design.

## Round D follow-up: device-log fixes (shipped)

Two follow-up fixes landed after Round D shipped (see each commit's own ADR):

- Fixed the device-log commands (`0x62` / `0x63`) to the format confirmed on real
  hardware, correcting the earlier guessed layout now that on-device testing had
  settled it (`docs/PROTOCOL.md` §6.5 / §6.6).
- Made log import skip records already pulled in during the same power cycle, since
  the device's internal log is volatile and resets to 0 records on every power-on —
  only newly logged records are imported on a later connection.

## Follow-up not yet done

- Translating comments in `App/Muzzlemeter/**` to English was out of scope for the
  documentation translation pass (2026-09) — the tree is too large for that pass. Left
  as a follow-up.
