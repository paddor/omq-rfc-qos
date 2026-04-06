# ZMTP Quality of Service (QoS)

| Field       | Value                                          |
|-------------|------------------------------------------------|
| Status      | Experimental                                   |
| Editor      | Patrik Wenger <paddor@gmail.com>               |
| References  | [23/ZMTP](https://rfc.zeromq.org/spec/23/), [37/ZMTP](https://rfc.zeromq.org/spec/37/) |

**This specification is experimental.** The design is under active review
and may change in incompatible ways. Implementors should expect revisions.

This specification defines per-hop delivery guarantees for ZMTP 3.1
connections, using ACK/NACK command frames and hash digest-based message
identification.

## License

Copyright (c) 2026 Patrik Wenger.

This Specification is free software; you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation; either version 3 of the License, or (at your option) any
later version.

## Language

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be
interpreted as described in [RFC 2119](https://www.ietf.org/rfc/rfc2119.txt).

## Goals

ZeroMQ provides fast, asynchronous messaging but offers no delivery guarantees
beyond TCP's reliable byte stream. Messages can be silently lost during network
partitions, peer crashes, HWM overflow, or reconnection gaps. Applications that
need reliability must build their own acknowledgment layer on top.

This specification adds **per-hop** delivery guarantees inspired by
[MQTT's QoS levels](https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html#_Toc3901234).
The guarantees apply between directly connected peers, not end-to-end across
intermediaries (brokers, proxies).

### Design principles

* **Zero overhead at QoS 0.** The default behavior is unchanged. No ACK frames,
  no tracking, no hash computation.
* **Per-hop, not end-to-end.** Each connection independently enforces its QoS
  level. Multi-hop guarantees require each hop to use QoS.
* **Hash-based identification.** Messages are identified by their xxHash digest
  rather than sequence numbers. This avoids per-connection state for ID
  allocation and simplifies fan-out patterns.
* **Command-frame ACK/NACK.** Acknowledgments are ZMTP command frames, invisible
  to applications. They flow in the opposite direction to data messages.

## QoS Levels

| Level | Name           | Guarantee                                     |
|-------|----------------|-----------------------------------------------|
| 0     | Fire-and-forget | None (standard ZMQ behavior)                 |
| 1     | At-least-once  | Sender retries until ACK received             |

### Future levels (not specified here)

| Level | Name                | Guarantee                                   |
|-------|---------------------|---------------------------------------------|
| 2     | Exactly-once        | Sender sticks to one connection, no failover |
| 3     | Exactly-once + processed | Like 2, plus application-level NACK on error |

QoS 2 and 3 are reserved for future specification. Implementations MUST reject
QoS values outside the range they support.

## Handshake

### X-QoS READY Property

The QoS level is exchanged during the ZMTP handshake as a custom property in
the READY command (or INITIATE command for CURVE clients):

```
Property name:  "X-QoS"
Property value: ASCII decimal string ("0", "1", "2", "3")
```

When QoS is 0 (the default), the X-QoS property SHOULD be omitted to avoid
overhead. If absent, a peer's QoS level MUST be assumed to be 0.

### X-QoS-Hash READY Property

When QoS >= 1, the peer MUST also advertise its supported hash algorithms:

```
Property name:  "X-QoS-Hash"
Property value: ASCII string of algorithm identifiers in preference order (e.g. "xsXS")
```

Each character identifies one algorithm (see [Hash algorithm registry](#hash-algorithm-registry)).
The first character is the most preferred.

### QoS level matching

Both peers MUST advertise the same QoS level. If a peer receives a READY (or
INITIATE) with a different X-QoS value than its own, it MUST close the
connection immediately. Implementations MUST NOT silently fall back to QoS 0.

Rationale: silent degradation masks configuration errors and violates the
application's delivery expectations. A PUSH socket configured for at-least-once
delivery that silently drops to fire-and-forget defeats the purpose of QoS.

### Hash algorithm negotiation

Both peers send their supported algorithms in preference order via
`X-QoS-Hash`. The **effective algorithm** for the connection is determined by
the **sender's** preference list: the first algorithm in the sender's
`X-QoS-Hash` that also appears in the receiver's `X-QoS-Hash`.

If there is no overlap, the peer that detects the mismatch MUST close the
connection. This prevents a situation where ACKs use an algorithm the sender
cannot verify.

The negotiated algorithm is used for all ACK/NACK commands on the connection.
Each side computes only one hash per message — no multi-algorithm overhead.

### Interoperability with libzmq

libzmq and other ZMTP implementations that do not support this specification
will not send X-QoS, which is equivalent to QoS 0. A QoS >= 1 socket
connecting to a libzmq peer will see a QoS mismatch and drop the connection.
This is intentional — mixing guaranteed and unguaranteed peers would violate
delivery semantics.

## ACK/NACK Command Frames

### Wire format

ACK and NACK are standard ZMTP command frames. The command name is encoded
per [23/ZMTP Section 2.1](https://rfc.zeromq.org/spec/23/):

```
Command frame body:
  [1 byte name_length] [N bytes name] [command data]
```

#### ACK command

```
Name: "ACK" (3 bytes)
Data: [1 byte algorithm] [N bytes hash_digest]
```

#### NACK command (reserved for QoS 3)

```
Name: "NACK" (4 bytes)
Data: [1 byte algorithm] [N bytes hash_digest] [M bytes error_info]
```

### Hash algorithm registry

The first byte of the command data selects the hash algorithm:

| Prefix | Algorithm       | Digest size | Notes                                    |
|--------|-----------------|-------------|------------------------------------------|
| `x`    | XXH64           | 8 bytes     | Fast. Requires xxHash library.            |
| `s`    | SHA-1 truncated | 8 bytes     | Universally available in standard libraries. |

Both algorithms produce 8-byte (64-bit) digests. Collision probability
within the in-flight window is approximately N²/2⁶⁵ where N is the
number of un-ACK'd messages — negligible for any realistic HWM.

Future specifications MAY define additional algorithm prefixes with
different digest sizes. The digest size is determined by the algorithm
prefix byte; implementations MUST know the digest size for every
algorithm they support.

Implementations MUST support at least one algorithm. Implementations
SHOULD support `x` (XXH64) for performance and `s` (SHA-1 truncated) for
environments where only standard library hashing is available.

### Hash input

The hash digest MUST be computed over the **raw ZMTP wire bytes** of the
message, as produced by encoding each frame with its flags and size header.
This means frame boundaries are part of the digest.

Specifically, for a message with parts `[P0, P1, ..., Pn]`, the hash input is
the concatenation of the ZMTP frame encodings:

```
For each part Pi at index i:
  flags  = 0x01 (MORE) if i < n, else 0x00
  flags |= 0x02 (LONG) if Pi.bytesize > 255
  
  If LONG flag set:
    wire_frame = [flags:1] [size:8 big-endian] [Pi]
  Else:
    wire_frame = [flags:1] [size:1] [Pi]

hash_input = wire_frame_0 || wire_frame_1 || ... || wire_frame_n
digest     = XXH64(hash_input)               # for algorithm "x"
           = truncate64(SHA1(hash_input))     # for algorithm "s"
```

**Rationale:** Hashing raw wire bytes (instead of `parts.join("")`) ensures
that messages with different framings but identical concatenated payloads
produce different digests. For example, `["AB", "CD"]` and `["A", "BCD"]`
are distinct messages and MUST produce distinct hashes.

### Digest byte order

The 8-byte XXH64 digest MUST be encoded in **little-endian** byte order
(matching the native output of xxHash on most platforms).

The 8-byte SHA-1 truncated digest is the first 8 bytes of the SHA-1 output
(big-endian, as produced by SHA-1).

## Per-Socket-Type Behavior

### PUSH/PULL and SCATTER/GATHER

#### QoS 0 (default)

No change from standard behavior.

#### QoS 1

**Sender (PUSH/SCATTER):**

1. After sending a message, the sender computes its hash and stores the
   message in a **pending store** keyed by digest.
2. The sender starts an **ACK listener** task per connection. This task calls
   `receive_message` with a block that intercepts ACK command frames. (On
   write-only sockets, `receive_message` blocks indefinitely — the block is
   only invoked for command frames.)
3. When an ACK is received, the sender removes the matching entry from the
   pending store.
4. When a connection is lost, the sender MUST re-enqueue all pending messages
   for that connection back into the send queue. They will be delivered to the
   next available peer via round-robin.

**Receiver (PULL/GATHER):**

1. After receiving a message from the recv pump, the receiver computes its hash
   and sends an ACK command back to the sender on the same connection.
2. The ACK is sent **before** the message is delivered to the application. This
   acknowledges receipt at the ZMTP layer, not application processing.

**Retry behavior:**

* Over TCP: Do NOT retry on the same connection. TCP is a reliable stream —
  if the bytes were sent, the kernel will deliver them. Retry only after the
  TCP connection drops (detected by the ACK listener or send pump).
* Over inproc/IPC: Retry after `reconnect_interval` (with exponential backoff).
* Un-ACK'd messages add to the effective HWM, providing natural backpressure
  against traffic amplification.

### REQ/REP

#### QoS 0 (default)

No change from standard behavior.

#### Send/recv ordering

REQ sockets MUST enforce strict send/recv/send/recv alternation regardless of
QoS level. A REQ socket maintains a state flag:

* `:ready` — a send is allowed
* `:waiting_reply` — a receive is expected

Calling send while in `:waiting_reply` state, or receive while in `:ready`
state, MUST raise an error. The recv pump flips the state back to `:ready`
when a reply is delivered.

#### QoS 1

REQ/REP does not use ACK/NACK command frames. **The reply IS the
acknowledgment.**

At QoS 1, if the connection drops while in `:waiting_reply` state:

1. The REQ socket flips back to `:ready`.
2. The original request is re-enqueued to the send queue.
3. It is delivered to the next REP peer via round-robin.

This makes REQ/REP production-usable. Standard ZMQ REQ/REP can get "stuck"
when a REP peer dies between receiving the request and sending the reply.
With QoS 1, the REQ transparently retries on the next REP.

**Applications SHOULD ensure request handlers are idempotent**, as the same
request may be delivered to multiple REP peers.

REP sockets require no QoS-specific changes — replying is their normal
behavior.

### PUB/SUB, XPUB/XSUB, RADIO/DISH

#### QoS 0 (default)

No change from standard behavior.

#### QoS 1

**Publisher (PUB/XPUB/RADIO):**

1. The existing subscription listener (which reads SUBSCRIBE/CANCEL/JOIN/LEAVE
   commands) is extended to also handle ACK commands.
2. When an ACK is received, the publisher removes the matching entry from its
   pending store.
3. At QoS 1, the publisher SHOULD block when no subscribers are connected
   (rather than dropping messages silently as at QoS 0).

**Subscriber (SUB/XSUB/DISH):**

1. After receiving a message from the recv pump, the subscriber sends an ACK
   command back to the publisher on the same connection.

**Fan-out semantics at QoS 1:**

At QoS 1, a published message is sent to **all** matching subscribers (same as
QoS 0). Each subscriber independently ACKs. The publisher's pending store
tracks one entry per message — it is ACK'd when **any** subscriber ACKs.

Applications that need per-subscriber delivery tracking should use XPUB to
observe subscription events and implement higher-level logic.

## Inproc Transport

### Command queues

At QoS >= 1, inproc connections MUST have command queues for ACK/NACK flow,
even if the socket types would not normally require command support.

### DirectPipe bypass

The DirectPipe optimization (single-peer inproc bypass that skips ZMTP framing)
MUST be disabled at QoS >= 1. The recv pump is where ACK commands are sent, and
the DirectPipe bypass skips the recv pump.

## HWM Interaction

Pending (un-ACK'd) messages are "in flight" — they have left the send queue but
have not been confirmed. Implementations MAY count pending messages toward the
send HWM to provide backpressure.

The first version of this specification treats pending messages as out-of-band
(similar to TCP kernel buffers) and does not count them toward HWM. This may be
revised in future versions based on operational experience.

## xxHash

This specification uses [xxHash](https://github.com/Cyan4973/xxHash) by Yann
Collet (the creator of LZ4 and Zstandard). xxHash is chosen for:

* **Speed.** xxHash is the fastest general-purpose hash function family across all
  message sizes, from small (< 64 bytes) to large (> 1 MB).
* **Quality.** xxHash passes all tests in SMHasher and has excellent avalanche
  properties for a non-cryptographic hash.
* **Availability.** xxHash implementations exist for C, C++, Rust, Go, Python,
  Ruby, Java, and many other languages.

### Reference implementation

The reference hash computation (Ruby):

```ruby
require "xxhash"

# parts: Array of frozen binary Strings (message frames)
wire_bytes = Protocol::ZMTP::Codec::Frame.encode_message(parts)
digest     = [XXhash.xxh64(wire_bytes)].pack("Q<")  # 8 bytes, little-endian
```

## Security Considerations

* **xxHash is not cryptographic.** It does not protect against intentional
  collision attacks. An adversary who can inject messages could craft two
  different messages with the same XXH64 digest, causing a false ACK. To
  mitigate this, use a secure transport (TLS, CURVE) so that only authenticated
  peers can send messages. The `s` algorithm (SHA-1 truncated) is also not
  collision-resistant at 64 bits, despite SHA-1 being a cryptographic hash.

* **Collision probability.** With 64-bit digests and `N` messages in flight,
  the probability of an accidental collision is approximately `N² / 2⁶⁵`. With
  1000 in-flight messages, this is ~5.4 × 10⁻¹⁴. Applications with strict
  correctness requirements SHOULD add application-level sequence numbers.

* **Replay.** QoS 1 provides at-least-once delivery, not exactly-once.
  Applications MUST handle duplicate messages. Adding a sequence number or
  unique ID to the message payload is the standard approach.

* **Amplification.** A misbehaving peer that never ACKs could cause unbounded
  growth in the sender's pending store. Implementations SHOULD limit the
  pending store size (e.g. to `send_hwm`) and either block or drop messages
  when the limit is reached.
