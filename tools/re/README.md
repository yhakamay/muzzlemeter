# tools/re — リバースエンジニアリング作業ディレクトリ

`docs/PROTOCOL.md` を埋めるための材料置き場。中身（APK・デコンパイル結果・キャプチャログ）は
`.gitignore` 済みで、リポジトリにはコミットされない。

## 1. AceSoft APK の配置（ユーザー作業）

iOS 版 (.ipa) は暗号化されているため、Android 版の公式アプリを静的解析に使う。

- パッケージ名: `com.acetk.acesoft`
- バージョン: v1.2.28
- 入手先: apkcombo / uptodown などの APK ミラー
- 配置先: **`tools/re/acesoft.apk`**

## 2. デコンパイル

```sh
jadx -d tools/re/jadx tools/re/acesoft.apk
```

`jadx` は `brew install jadx` 済み。出力は `tools/re/jadx/`（gitignore 済み）。

### 見るべき箇所

```sh
# サービス / characteristic UUID
grep -rn "0000....-0000-1000-8000-00805f9b34fb" tools/re/jadx/ | sort -u

# GATT 操作
grep -rn "setCharacteristicNotification\|writeCharacteristic\|BluetoothGattCharacteristic" tools/re/jadx/

# パケットのパース処理（速度・単位・チェックサム）
grep -rni "velocity\|joule\|fps\|checksum\|crc" tools/re/jadx/
```

Flutter / React Native 製だった場合は Java 側にロジックが無いので、
`libapp.so` の文字列や `assets/index.android.bundle` を追う。

## 3. 実機キャプチャ

```sh
swift run acechrono-sniff scan --seconds 10
swift run acechrono-sniff dump --name AC6000
```

ログは `tools/re/captures/<yyyyMMdd-HHmmss>.log` に自動保存される（gitignore 済み）。
解析が済んだ代表パケットは `Tests/AceChronoKitTests/Fixtures/` に手で書き出して回帰テストにする。
