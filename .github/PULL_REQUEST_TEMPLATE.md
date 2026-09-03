## Summary

<!-- What does this change, in 1-3 lines? -->

## ADR (required whenever the change involves a design choice)

In this repository, **any commit that involves a design or architecture choice must
carry an ADR in the commit message body.** A squash merge's commit body inherits this
PR's own body, so filling in the sections below keeps that record in the merged history.
(Purely mechanical changes — typos, formatting, a dependency bump with no real choice
involved — may skip the ADR.)

### Context

<!-- Why is this change needed? What are the constraints? -->

### Decision

<!-- What was chosen? Be concrete. -->

### Alternatives considered

<!-- Each rejected option, and why it was rejected. At least one line per option. -->

### Consequences

<!-- Trade-offs, follow-ups, what becomes easier or harder. -->

## Checks

- [ ] `swift test` passes
- [ ] `xcodegen generate` → the iOS app builds (if `project.yml` was touched)
- [ ] Verified behavior on real hardware or via replay (if the UI was touched)
- [ ] Anything added to `docs/PROTOCOL.md` is a fact **observed firsthand**
      (information obtained by decompiling someone else's app is not accepted)
- [ ] No destructive opcode was added (`0x61` CLEAR_LOG, or a write to the OTA
      characteristic)
