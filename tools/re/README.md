# tools/re — プロトコル調査の作業ディレクトリ

`docs/PROTOCOL.md` を埋めるための材料置き場。中身（キャプチャログ・作業メモ）は
`.gitignore` 済みで、リポジトリにはコミットされない（`README.md` と
`captures/.gitkeep` だけを追跡している）。

## 通信キャプチャ

`docs/PROTOCOL.md` の内容は、次の 2 つの実測から得ている。

1. **iPhone の HCI ログ**（Apple の PacketLogger で取得した `.pklg`）。
   公式アプリと本体のあいだで実際に流れたフレームをそのまま観察する。
2. **自作クライアントでの追試**。仮説を立てて本体に投げ、応答を確かめる。

### 自作サニファでのキャプチャ

```sh
swift run muzzlemeter-sniff scan --seconds 10
swift run muzzlemeter-sniff dump --name AC6000BT- --handshake
```

ログは `tools/re/captures/<yyyyMMdd-HHmmss>.log` に自動保存される（gitignore 済み）。
`ReplayScript` がこの形式をそのまま読めるので、取ったログはアプリの再生にも使える。

解析が済んだ代表パケットは `Tests/MuzzlemeterKitTests/Fixtures/` に手で書き出して
回帰テストにする。

### 注意

- `docs/PROTOCOL.md` に載せるのは**自分で観測した事実**だけにすること。
- 危険な opcode（`0x61` CLEAR_LOG、OTA characteristic への書き込み）は
  送らない。`docs/PROTOCOL.md` §11 を読むこと。
