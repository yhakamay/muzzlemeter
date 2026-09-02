# AC6000 MKIII BT BLE プロトコル

Acetech AC6000 MKIII BT の BLE 通信仕様。公式ドキュメントは存在しないため、
`acechrono-sniff` による実機ダンプと AceSoft (Android, `com.acetk.acesoft`) の
逆コンパイル結果から確定させていく。

ステータス: **未解析（Phase 1 で埋める）**

## Device identification

アドバタイズされるデバイス名、サービス UUID、manufacturer data。

TBD

## GATT layout

サービスと characteristic の一覧（UUID / プロパティ / 役割）。

TBD

## Init sequence

接続後に必要な書き込み（開始コマンド等）と、その順序・タイミング。

TBD

## Packet formats

### Shot

1 発ごとの弾速パケット。ヘッダ、長さ、速度のエンコーディング（単位・スケール）、
連番、タイムスタンプの有無。

TBD

### Status

本体設定（単位、BB 重量、電源、バッテリー）に関する通知。

TBD

### Other

上記に当てはまらないパケット。

TBD

## Checksum

チェックサム / CRC の計算範囲とアルゴリズム。

TBD

## Open questions

- 連射時の ROF は本体が送ってくるのか、ホスト側でタイムスタンプ差から計算するのか
- ペイロードに難読化・暗号化があるか
- MKIII と初代 BT でパケットが異なるか（バージョン識別の手段）

TBD
