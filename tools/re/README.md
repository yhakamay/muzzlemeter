# tools/re — the working directory for protocol research

The material used to fill in `docs/PROTOCOL.md`. The contents (capture logs, working
notes) are gitignored and never committed to the repository (only `README.md` and
`captures/.gitkeep` are tracked).

## Communication captures

`docs/PROTOCOL.md`'s content comes from two kinds of measurement.

1. **iPhone HCI logs** (`.pklg` files captured with Apple's PacketLogger). Observing the
   frames that actually flowed between the official app and the device, directly.
2. **On-device testing with the custom client.** Forming a hypothesis, sending it to the
   device, and checking the response.

### Capturing with the custom sniffer

```sh
swift run muzzlemeter-sniff scan --seconds 10
swift run muzzlemeter-sniff dump --name AC6000BT- --handshake
```

The log is saved automatically to `tools/re/captures/<yyyyMMdd-HHmmss>.log` (gitignored).
`ReplayScript` can read this format directly, so a freshly captured log can also be used
to replay the app.

Once a representative packet has been analyzed, it's hand-transcribed into
`Tests/MuzzlemeterKitTests/Fixtures/` and turned into a regression test.

### Caution

- Only put **facts you observed yourself** into `docs/PROTOCOL.md`.
- Never send a dangerous opcode (`0x61` CLEAR_LOG, or a write to the OTA
  characteristic). Read `docs/PROTOCOL.md` §11 first.
