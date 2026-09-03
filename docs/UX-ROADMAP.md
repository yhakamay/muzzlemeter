# UX ロードマップ（2026-09-03 ユーザー合意）

## データモデルの棲み分け（Round A・実装済み）

| 置き場所 | 項目 |
|---|---|
| プロファイル（銃そのもの） | 名前 / メーカー / モデル / パワーソース区分（電動・ガス・エアコッキング・HPA）/ インナーバレル長 / 規制上限 J（既定 0.98、変更可）/ メモ / セッション変数の既定値（BB 重量・ガス種別・ホップ設定） |
| セッション（その回の条件） | BB 重量 / ガス種別（区分がガスのときのみ）/ ホップ設定 / タグ / メモ / 名前 / 環境データ（自動＋手動上書き） |

- セッションは最初の 1 発でプロファイル既定値により自動開始（ブロッキング UI なし）。
- Live のプロファイルピル直下に「0.25 g · HFC134a · ホップ 3」を表示し、タップでセッション変数を変更。変更はセッション全体に適用（ジュール再計算）。
- 既存の GunProfile.powerSource（ガス種別込み）は「区分」と「ガス種別」に分割し、既存データを移行する。

実装メモ（該当コミットの ADR に詳細）:

- セッション変数は値型 `SessionVariables`（BB 重量・ガス種別・ホップ）。プロファイルは
  その**既定値**だけを持ち、セッションが開始時にスナップショットする。
- 待機中の「次に始まる条件」は `ChronoService.pendingVariables`（永続化しない）。
- 移行は列の追加＋起動時の値の派生（`StoreMigration`）。`VersionedSchema` は使っていない。
- `bbWeightGrams` / `hopNotes` は列名を据え置き、`defaultBBWeightGrams` /
  `defaultHopSetting` という別名で呼ぶ。
- CSV: `power_source` → `power_category`、`gas_type` / `hop_setting` / `energy_limit_j` を追加。

## Round B: Live 周り
1. ✅ 規制値ライン（プロファイル上限に対し 余裕/注意/超過 の色分け、超過時ハプティクス＋音）
2. ✅ 本体の Ammo 設定（0x47）とプロファイル BB 重量の不一致警告
3. ✅ 弾速の読み上げ（ON/OFF）
5. ✅ 目標発数で自動的にセッションを締める「N 発モード」
11. ✅ スキャン中に見つかった本体名と RSSI を表示（複数台での取り違え防止）

実装メモ（詳細は該当コミットの ADR）:

- **1. 規制値ライン**: 判定は `MuzzlemeterKit.EnergyLimit`（`margin(joules:limitJoules:)`）に置いた。
  上限の 90 % 以下 = 余裕 / 90 % 超〜上限未満 = 注意 / **上限ちょうど以上 = 超過**（安全側）。
  色は `EnergyMargin.tint` の 1 箇所で決め、Live の巨大数字・直近リスト・履歴のリストと
  チャートで同じ色を使う。音と振動は `FeedbackService`（`ChronoService` から分離。
  音は `AVAudioSession` の `.ambient` = サイレントスイッチに従う）。
  「余裕」は**そのセッションで最も高かった 1 発**を基準にする（平均だと外れ値を見落とす）。
- **2. Ammo 不一致**: `AmmoRecord.weightGrams` を optional にし、raw が 100 以上なら ×1000、
  未満なら ×100 と読む（`docs/PROTOCOL.md` §6.4 の 2 つのスケールを両方受け入れる）。
  実在しない重量になる値は `nil`。`0x5A` は常に、`0x47` は自発通知（marker 0x40）だけを
  「いま選ばれている弾」として採る。差が 0.005 g を超えたら接続ピルの下に帯を出し、
  「セッションを 0.20 g にする」「無視」の 2 択。**本体には書き込まない。**
- **3. 読み上げ**: `AVSpeechSynthesizer`。文言は画面と同じ整形を通す（表示 92.5 なら
  「きゅうじゅうにてんご」）。オーディオセッションは通知音が `.ambient`（サイレント
  スイッチに従う）、読み上げが `.playback` + `.duckOthers`（**従わない**）で、
  意図的に扱いを変えている。理由は設定の説明文に書いてある。
  フルオートでは前の発言を打ち切って最新だけを読む。
- **5. N 発モード**: `ShotTarget`（キット。`nil`/0/負数は成立しない）で判定する。
  **ちょうどでも超えても締める**（フルオートで行き過ぎるため）。目標発数は
  `SessionVariables` に入れた（プロファイルが既定値、セッションで上書き）。
  締めるのは**保存の後**。まとめは画面に重ねて出し、「もう一度」＝同じ条件で継続、
  「閉じる」＝目標発数を解除。ボタンの違いは説明文で明示する。
- **11. スキャン表示**: キットに `DiscoveryList`（前回接続 → 電波の強い順に並べる）と
  `DiscoveredPeripheral.signalBars`（RSSI → 0〜4 本）を足し、`ChronoEvent.discovered` で
  **変化したときだけ**配信する。RSSI を追うために CoreBluetooth のスキャンを
  `allowDuplicates: true` にした。接続ピルをタップするとシートが開き、選んだ機器へ
  繋ぎ直せる。自動接続は止めず、**上書きするための入口**として足している。

## Round C: 分析
6. ✅ セッション比較（2〜3 件の統計並置＋重ね合わせグラフ）
7. ✅ タグ付けと絞り込み
9. ✅ プロファイル詳細に平均弾速の時系列と気温との散布図

実装メモ（詳細は該当コミットの ADR）:

- **6. セッション比較**: 比較の入口は履歴一覧の選択モードとセッション詳細の
  「他のセッションと比較」の 2 つで、どちらも `SessionComparisonRequest`（2〜3 件）
  という**値**に落として同じ遷移先へ入る。表の「どの値が良いか」は
  `MuzzlemeterKit.ComparisonTable` に置き、**向きのある項目（SD・ES・超過発数）だけ**に
  印を付ける（平均や最大に印を付けると「印のほうが良い」と誤読させる）。
  印は色ではなく淡い地色＋太字。色は規制上限の橙 / 赤と衝突させない。
  系列色も同じ理由で青・紫・ティール（橙と赤を避ける）。統計はビューを開いたときに
  1 回だけ計算して `SessionComparisonEntry` に持つ。
- **7. タグ**: 保存は既存の `Session.tagsRaw`（改行区切りの 1 列）のまま。整形・重複潰し・
  同一判定・絞り込みは `MuzzlemeterKit.SessionTags` / `SessionFilter` に集めた
  （保存側と絞り込み側で「同じタグ」の判定がずれないため）。同一判定は
  **大文字小文字と全角半角は無視、濁点は無視しない**（日本語では意味が変わる）。
  絞り込みは SwiftData の述語ではなく取得済み配列に当てる。タグは AND、
  文字検索はタイトル・メモ・タグの OR。絞り込みの帯を上に貼り付けると大きい
  タイトルと場所が食い違って「履歴」が消えるので、履歴だけタイトルを inline にした。
  CSV には `tags` 列（セミコロン区切り）を追加。
- **9. プロファイルの推移**: 設定のプロファイル行は編集シートではなく**詳細画面**へ
  遷移する（編集は詳細の「編集」）。Live のプロファイルメニューからも
  「プロファイルの詳細」でシートとして開ける（計測中に画面を押しのけないため）。
  時系列・散布図・まとめの計算は `MuzzlemeterKit.ProfileTrend`。全体の SD は
  **セッションごとの SD の平均ではなく**、全ショットを 1 つの標本として見た標本 SD
  （分解式 `(N−1)s² = Σ(nᵢ−1)sᵢ² + Σnᵢ(mᵢ−M)²`）。散布図は気温のある回だけで、
  3 件未満のときは「傾きを読み取るには足りない」と断る。セッションとの結び付けは
  **セッションに記録された銃名**（プロファイルを参照させない設計を維持するため、
  プロファイル名を変えると過去の回は出てこなくなる）。

## Round D: 本体内ログの取り込み（0x62 件数 / 0x63 読み出し。0x61 消去は実装しない）

## Round E: 拡張ターゲット
4. ✅ ライブアクティビティ（Dynamic Island / ロック画面）
10. ホーム画面ウィジェット
12. Apple Watch の弾速表示

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
