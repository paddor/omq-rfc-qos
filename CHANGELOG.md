# Changelog

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
