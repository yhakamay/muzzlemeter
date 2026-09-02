# AceChrono

Acetech **AC6000 MKIII BT**（エアソフト用弾速計）を、公式アプリ「AceSoft」より使いやすい
自作 iOS アプリで扱うためのプロジェクト。

BLE プロトコルが非公開のため、**プロトコル解析から始める**。現在は

- Phase 0（土台）と解析用 macOS CLI `acechrono-sniff`
- Phase 2（`AceChronoKit`: ドメイン・BLE 抽象・`ChronoDevice`）
- Phase 3（iOS アプリの骨格。デモ再生で全画面が動く）

まで完了。**実機の BLE プロトコルはまだ未確定**なので、アプリはリプレイ（記録済みパケットの
再生）でのみ動作する。パケットパーサと実機トランスポートは解析完了後に追加する。

## 構成

| パス | 内容 |
|---|---|
| `Sources/AceChronoKit/` | ドメイン・プロトコル・BLE 抽象（iOS / macOS 共通ライブラリ） |
| `Sources/AceChronoSniff/` | macOS CLI。BLE スキャン / GATT 列挙 / パケットダンプ |
| `Tests/AceChronoKitTests/` | Swift Testing によるテスト |
| `docs/PROTOCOL.md` | 解析結果（UUID・パケット形式・チェックサム） |
| `tools/re/` | APK / jadx 出力 / キャプチャログ（gitignore） |
| `App/AceChrono/` | iOS アプリ（SwiftUI + SwiftData） |
| `project.yml` | XcodeGen 定義。`.xcodeproj` はここから生成する |

## acechrono-sniff の使い方

### スキャン

周囲の BLE アドバタイズを一覧表示する。本体の電源を入れて実行し、機器名を確認する。

```sh
swift run acechrono-sniff scan
swift run acechrono-sniff scan --seconds 30
swift run acechrono-sniff scan --filter-service ffe0
```

出力例（1 行 1 デバイス、identifier で重複排除）:

```
name: AC6000  id: 1A2B3C4D-...  rssi: -54  services: [FFE0]  mfg: 4c 00 12 ...
```

### ダンプ（接続して解析する）

接続 → 全 service / characteristic を列挙 → read 可能なものを 1 回ずつ read →
notify / indicate を全部購読 → 受信パケットをタイムスタンプ付き hex で流し続ける。
Ctrl-C で終了。切断されたら自動で再接続を試みる。

```sh
swift run acechrono-sniff dump --name AC6000
swift run acechrono-sniff dump --id 1A2B3C4D-5E6F-...   # scan で出た identifier
swift run acechrono-sniff dump --name AC6000 --log tools/re/captures/single-shot.log
```

パケット行の形式:

```
[2026-09-02T22:31:04.512+09:00] [+412.7 ms] FFE1 len=8 hex: aa 55 01 5a ... ascii: .U.Z....
```

ログは指定しなければ `tools/re/captures/<yyyyMMdd-HHmmss>.log` に自動保存される。

### 初期化コマンドを送る

本体が「計測開始コマンド」を要求する場合に使う（APK 解析で判明したバイト列を送る）。
購読完了後に送信され、結果が表示される。`--write` は複数回指定できる。

```sh
swift run acechrono-sniff dump --name AC6000 --write ffe1 01a50000 --write ffe1 02
swift run acechrono-sniff dump --name AC6000 --write ffe1=01a50000   # = 区切りでも可
```

`--write` を複数指定した場合、既定では **200 ms 間隔**で 1 件ずつ送る。どの write に対する
応答なのかを対応付けられるようにするためで、間隔は `--write-delay <ms>` で変えられる
（`0` で連続送信）。

```sh
swift run acechrono-sniff dump --name AC6000 --write ffe1 01 --write ffe1 02 --write-delay 500
```

#### write の種別（`--write-type`）

BLE の write には **withResponse**（相手が ATT の応答を返す）と **withoutResponse**
（撃ちっぱなし）がある。どちらを受け付けるかはファームウェア次第で、**片方しか処理しない**
実装や、プロパティの申告と実際の挙動が食い違う実装がある。そのため種別は明示的に選べる。

| 値 | 動作 |
|---|---|
| `auto`（既定） | `write` プロパティがあれば withResponse、無ければ withoutResponse |
| `with` | プロパティに関わらず **常に withResponse** |
| `without` | プロパティに関わらず **常に withoutResponse** |

`with` / `without` はプロパティを持たない characteristic に対しても強制的に送る（注意行を出す）。
申告が当てにならない相手を試せることがこのオプションの目的だから。

```sh
swift run acechrono-sniff dump --name AC6000 --write-type without --write ffe1 850600
```

`--write-type` は `--write` と、対話モードの `<hex>` / `w` の**既定値**になる。
対話モードでは `wr` / `wn` で 1 回ごとに上書きできる。

### 対話モード（ハンドシェイクの試行錯誤用）

`--interactive`（短縮 `-i`）を付けると、GATT 列挙・購読・`--write` の送信が終わった後に
**stdin から 1 行ずつコマンドを受け付ける**。バイト列を 1 つ試すたびに接続し直す必要が
なくなるので、未知のハンドシェイクを総当たりで探るときはこれを使う。

```sh
swift run acechrono-sniff dump --name AC6000 --interactive
swift run acechrono-sniff dump --name AC6000 -i --write ffe1 01a50000   # 初期化してから対話
swift run acechrono-sniff dump --name AC6000 -i --write-type without    # 既定を without に
```

受け付けるコマンド:

| 入力 | 動作 |
|---|---|
| `5a 4b 00 4b` / `5a4b004b` | **既定の write characteristic** へ送る（種別は `--write-type`） |
| `w <char> <hex>` | characteristic を指定して write（種別は `--write-type`） |
| `wr [<char>] <hex>` | **withResponse** で write |
| `wn [<char>] <hex>` | **withoutResponse** で write |
| `r <char>` | characteristic を read |
| `sub <char>` / `unsub <char>` | notify の購読 / 解除 |
| `mtu` | 1 回の write で送れる最大バイト数を表示 |
| `list` | GATT ツリーを再表示（`*notifying*` 付き） |
| `h` | ヘルプ |
| `q` / Ctrl-D | 切断して終了 |

- `<char>` は characteristic UUID（`ffe1` のような短縮形も可）か、**一意に決まる前置一致**。
  複数に当たる場合は候補を表示して何もしない。
- **既定の write characteristic** は、write（応答あり）を持つ最初の characteristic。
  無ければ writeWithoutResponse を持つ最初のもの。開始時に write の既定種別と一緒に表示される。
- `wr` / `wn` の `<char>` は省略できる。**トークンが 2 つ以上あり、先頭が 4 / 8 / 36 桁**の
  ときだけ characteristic 指定と解釈する。`wn 85 06 4b` の `85` は 2 桁なので hex のまま。
  4 桁区切りの hex を既定の宛先へ送りたいときは `wn 85064b00` と空白を詰める。
- **1 行に `;` 区切りで複数フレームを書ける**。`--write-delay` の間隔で順に送られるので、
  ハンドシェイクのように続けて投げる必要がある列を 1 行で試せる:

  ```
  > 85 06 4b 00 00 d6 ; 85 05 5a 00 e4
  > wn 8506 ; wr ffe1 5a00 ; r ffe1
  ```

  どれか 1 つでも解釈できない場合は**何も送らない**（打ち間違いで前半だけ送るのを防ぐため）。
- 空行と `#` で始まる行は無視される。解釈できない入力は 1 行の usage を出す。
- 対話中の write / read / 結果は**キャプチャログにもそのまま記録される**ので、
  後から `ReplayScript` で読み直せる。

`mtu`（と接続直後の自動表示）が出す `maximumWriteValueLength` は、フレームが長すぎて
途中で切られているのか、そもそも届いていないのかを切り分けるのに使う。withoutResponse は
ネゴシエートされた ATT_MTU から 3 バイト引いた値、withResponse は分割送信されるため
最大 512 が返るのが普通。

```
最大 write 長: withResponse=512 bytes  withoutResponse=182 bytes
```

notify は入力中でも非同期に流れてくるため、プロンプト `> ` は**起動直後と各コマンドの結果の
直後だけ**表示される（毎回出すとパケットで画面が埋まるため）。

候補のバイト列をファイルやパイプで流し込むこともできる。**端末以外から読んでいるときは
`--write-delay` の間隔で 1 行ずつ処理する**ので、どの応答がどの行のものか分かる:

```sh
printf '5a4b004b\n5a4b014c\n' | swift run acechrono-sniff dump --name AC6000 -i
swift run acechrono-sniff dump --name AC6000 -i --write-delay 500 < candidates.txt
```

### macOS の Bluetooth 権限

CLI から CoreBluetooth を使うと、**ターミナルアプリ自体**に Bluetooth 権限が必要になる。
初回実行時に許可ダイアログが出る。出ない・拒否してしまった場合は

**システム設定 > プライバシーとセキュリティ > Bluetooth**

で Terminal.app（または iTerm.app など実行元のアプリ）を ON にし、
**そのアプリを再起動**してから実行し直す。

重要な注意:

- 権限の判定対象は **プロセスを起動した親アプリ（responsible process）** であって
  `acechrono-sniff` 自身ではない。エディタや他のツールの統合ターミナルから起動すると
  そのアプリに権限が無く、macOS が問答無用でプロセスを **SIGABRT で強制終了** する
  （その場合は原因を説明するメッセージを stderr に出して終了する）。
  **Terminal.app / iTerm.app から直接実行すること。**
- CLI 実行ファイルには `NSBluetoothAlwaysUsageDescription` を含む Info.plist を
  `__TEXT,__info_plist` セクションに埋め込んでいる（`Package.swift` のリンカ設定と
  `Sources/AceChronoSniff/Info.plist`）。これが無いと CoreBluetooth 初期化時に必ず落ちる。
- Bluetooth がオフ、または権限が拒否されている場合は、その旨を表示して終了コード 1 で終わる。

## ビルド

### AceChronoKit と CLI

**Command Line Tools のツールチェーン（Swift 6.4）だけで動く**。

```sh
swift build
swift test
```

### iOS アプリ

`.xcodeproj` は `project.yml` から **XcodeGen で生成する成果物**であり、リポジトリには
含まれていない（gitignore）。クローン後、あるいは `project.yml` やファイル構成を変えたら
**必ず最初に実行する**:

```sh
xcodegen generate          # → AceChrono.xcodeproj
```

その後:

```sh
open AceChrono.xcodeproj
# または
xcodebuild -project AceChrono.xcodeproj -scheme AceChrono \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

`xcodebuild` を使うには Xcode 側のツールチェーンが必要（**ユーザー作業**、要パスワード）:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

CLI の `swift build` / `swift test` にはこれは**不要**。

### デモ（リプレイ）モード

実機の BLE プロトコルが未確定なので、アプリは現状 **記録済みパケットの再生でのみ動く**。

- **シミュレータでは自動的に**リプレイモードになる（CoreBluetooth のハードウェアが無いため）
- 実機でも起動引数 `--replay` を付ければリプレイモードになる

再生されるデータは `App/AceChrono/Resources/demo-replay.txt`。形式は

```
+<先頭からのミリ秒> <characteristic UUID> <hex バイト列>
```

`ReplayScript` は **`acechrono-sniff dump` のログ形式もそのまま読める**ので、実機キャプチャが
取れたらこのファイルを差し替えるだけで本物のデータで UI を確認できる。
なお現在のデモ用ペイロードのバイト並びは `App/AceChrono/Services/DemoReplay.swift` で
**このアプリのために勝手に決めた仮のもの**で、AC6000 の実プロトコルとは無関係。

## プロトコル解析

手順は `tools/re/README.md`、結果は `docs/PROTOCOL.md` を参照。
ユーザー作業として、AceSoft の Android APK (`com.acetk.acesoft` v1.2.28) を
`tools/re/acesoft.apk` に配置してもらう必要がある。
