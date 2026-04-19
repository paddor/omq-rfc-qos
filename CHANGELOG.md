# Changelog

## Unreleased

### Changed

- **Gem renamed to `omq-qos`** (from `omq-rfc-qos`). Require path moves
  from `omq/rfc/qos` to `omq/qos`; library code relocated from
  `lib/omq/rfc/qos/` to `lib/omq/qos/`. The `rfc/` namespace was an
  unnecessary layer — this is a plugin gem, not a spec repository.

### Removed

- **Fan-out QoS dropped.** PUB/SUB, XPUB/XSUB, and RADIO/DISH are no
  longer QoS targets. Setting `qos >= 1` on any fan-out socket now
  raises `ArgumentError` at the setter. ACK-per-subscriber on fan-out
  was always a poor fit (no meaningful retry target, per-message hash
  state explodes with N subscribers) — the RFC and README now state
  this explicitly. QoS 1 remains supported on PUSH/PULL,
  SCATTER/GATHER, and REQ/REP.

## 0.2.0 — 2026-04-15

### Changed

- **Requires omq ~> 0.21.** Routing extensions track the shared-queue
  recv path introduced in omq 0.21 (no more `FairQueue` / `SignalingQueue`).

### Fixed

- **Rebuilt against current omq routing API.** Routing extensions now
  match the post-0.20 omq contracts (`RoundRobinExt`, `PushExt`,
  `ScatterExt`, `PullExt`, `GatherExt`, `FanOutExt`, `SubExt`,
  `XSubExt`, `DishExt`).
- **Inproc DirectPipe short-circuit.** QoS hooks now skip DirectPipe
  peers (inproc delivery is synchronous; ACKs are not meaningful there).
- **ACK command dispatch** now goes through a new `ConnectionExt`
  prepend on `Protocol::ZMTP::Connection` (`qos_on_command` hook),
  avoiding any change to core omq's recv pump.
- `EngineExt` removed; handshake QoS negotiation lives in a new
  `LifecycleExt` prepended onto `Engine::ConnectionLifecycle`.
- **REQ no longer double-enqueues on mid-flight disconnect.** The old
  `ReqExt` override re-enqueued the pending request on top of
  `RoundRobinExt`'s pending-store replay, and incorrectly flipped
  `@state` back to `:ready` while a request was still outstanding.
  `RoundRobinExt` already handles the replay; `ReqExt` is removed.

### Added

- **Bounded pending store with backpressure.** `PendingStore` now takes
  a `capacity:` (sized to `send_hwm`) and exposes `#wait_for_slot`.
  `RoundRobinExt#write_batch` waits for a free slot before sending, so a
  peer that stops ACKing stalls the sender instead of growing the store
  unboundedly. `#ack` and `#messages_for` signal an
  `Async::Notification` to wake blocked senders.
- Multi-message in-flight replay test for QoS 1 PUSH/PULL.
- SIGKILL peer-process replay test for QoS 1 PUSH/PULL (forks a child
  PULL, kills it hard, asserts pending messages land on a backup).
- README sections on backpressure and `linger: 0` semantics.

### Changed

- Test suite rewritten for the omq 0.20 socket API (setter-based
  `linger`/`qos`/`reconnect_interval`, top-level `SocketError`, explicit
  `SUB#subscribe`).

## 0.1.1 — 2026-04-07

- YARD documentation on all public methods and classes.
- Code style: expand `else X` one-liners, two blank lines between methods
  and constants.

## 0.1.0

Initial release.

### Added

- **QoS 1 (at-least-once)** delivery via ACK command frames and xxHash/SHA-1
  message identification.
- **Hash algorithm negotiation** — `X-QoS-Hash` READY property. Peers
  advertise supported algorithms in preference order; first common match
  is used per connection. No overlap → connection dropped.
- **Strict QoS matching** — peers MUST advertise the same QoS level.
  Mismatch drops the connection immediately (no silent fallback to QoS 0).
- **Supported algorithms** — `x` (XXH64, 8 bytes) and `s` (SHA-1 truncated
  to 64 bits). Future algorithms MAY use different digest sizes.
- **Socket types** — PUSH/PULL, SCATTER/GATHER, PUB/SUB, XPUB/XSUB,
  RADIO/DISH (ACK command frames), REQ/REP (reply = ACK, retry on
  disconnect).
- **PendingStore** — tracks sent-but-unACK'd messages per routing strategy.
  On connection loss, unacked messages are re-enqueued for the next peer.
- **Zero overhead at QoS 0** — all prepends check `engine.options.qos`
  and fall through to original behavior.
- **RFC** — `rfc/zmtp-qos.md` specifying wire format, handshake
  properties, per-socket-type behavior, and security considerations.
