# AceChrono

Acetech **AC6000 MKIII BT**（エアソフト用弾速計）を、公式アプリ「AceSoft」より使いやすい
自作 iOS アプリで扱うためのプロジェクト。

BLE プロトコルが非公開のため、**プロトコル解析から始める**。現在は Phase 0（土台）が完了し、
解析用の macOS CLI `acechrono-sniff` が動く状態。

## 構成

| パス | 内容 |
|---|---|
| `Sources/AceChronoKit/` | ドメイン・プロトコル・BLE 抽象（iOS / macOS 共通ライブラリ） |
| `Sources/AceChronoSniff/` | macOS CLI。BLE スキャン / GATT 列挙 / パケットダンプ |
| `Tests/AceChronoKitTests/` | Swift Testing によるテスト |
| `docs/PROTOCOL.md` | 解析結果（UUID・パケット形式・チェックサム） |
| `tools/re/` | APK / jadx 出力 / キャプチャログ（gitignore） |
| `App/AceChrono/` | iOS アプリ（後のマイルストーンで追加） |

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

write プロパティがあれば withResponse、無ければ withoutResponse で送る。

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

CLI とテストは **Command Line Tools のツールチェーン（Swift 6.4）だけで動く**。

```sh
swift build
swift test
```

iOS アプリ（後のマイルストーン）をビルドする段階になったら、`xcodebuild` を使うため
Xcode 側のツールチェーンに切り替える必要がある（パスワード入力が必要な**ユーザー作業**）:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

これは CLI の `swift build` / `swift test` には**不要**。

## プロトコル解析

手順は `tools/re/README.md`、結果は `docs/PROTOCOL.md` を参照。
ユーザー作業として、AceSoft の Android APK (`com.acetk.acesoft` v1.2.28) を
`tools/re/acesoft.apk` に配置してもらう必要がある。
