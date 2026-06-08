# Tradeoff analysis — UdpSender robustness

Design note explaining how `UdpSender` resolves the daemon address and binds its
socket, and why the tracing transport can never fault the traced operation.

## Problem

`lib/src/sender/udp_sender.dart` has four defects that make the tracing
transport able to *fault the traced operation* — violating the constitution's
"a transport or context failure must never fault the traced operation."

1. **DNS `lookup()` on every send** (`sendPackets`, every call).
2. **Socket bind race** — `_ipv6Socket ??= await bind(...)`: the `== null`
   check is evaluated before the `await`, so two concurrent sends both bind and
   the second assignment leaks the first socket.
3. **`lookup`/`bind` errors escape** — only `socket.send` is wrapped in `try`;
   a transient DNS failure or socket exhaustion propagates out of `sendPackets`
   → `closeSegment` → the user's awaited `run()`.
4. **Per-packet `dart:developer` log** on the hot path.

## Options (address/socket lifecycle — the real choice)

Error containment is mandatory (constitution), not a tradeoff. The genuine
decision is how to resolve and cache the daemon address + socket.

Weighted criteria — Safety ×3, Lambda-correctness ×3, Hot-path latency ×2,
Simplicity ×2, Staleness-robustness ×1 (max 55):

| Option | Safety | Latency | Lambda | Simplicity | Staleness | Total |
|---|---|---|---|---|---|---|
| 1. Eager init at construction | 4 | 5 | 4 | 3 | 2 | 42 |
| **2. Lazy memoized init + IP fast-path** ⭐ | 5 | 5 | 5 | 4 | 3 | **51** |
| 3. Per-send resolve, cached socket, guarded | 5 | 3 | 5 | 3 | 5 | 47 |

### Recommendation: Option 2

- **Memoize a single in-flight `Future<_Conn>`** (`_conn ??= _connect()`). The
  future is assigned synchronously before any `await`, structurally eliminating
  the bind race — dedupe on the *future*, not the result.
- **IP-literal fast path** — `InternetAddress.tryParse(host)` handles
  `127.0.0.1` / `169.254.100.1` (incl. Lambda link-local) with zero DNS; fall
  back to a one-time memoized `lookup()` only for real hostnames.
- **Collapses the dual-socket complexity** — exactly one resolved address ⇒ one
  bound socket of the matching family; the IPv4/IPv6 branching disappears.
- **Lambda-correct** — lazy (not construction-time) resolution reads the
  cold-start daemon address after the env is set.

Option 1 loses on Dart's awkward async-in-constructor and premature binding;
Option 3's per-send `lookup` is needless work for a process-static daemon
address.

## Cross-cutting decisions

- **Total error containment** — wrap the whole `sendPackets` body; nothing
  escapes. `send()` delegates to it.
- **Observability** — optional `onError(Object)` callback replaces the
  hardcoded `dev.log`; default silent. (No success callback; no per-packet log.)
- **Failed resolution is not cached** — re-attempted on later sends so a
  late-starting daemon recovers; only successful resolution is memoized.
- **`close()` is re-openable** — closes the socket and resets the memo.

## Known limitation (must be documented, not engineered around)

UDP has **no delivery acknowledgment**. A datagram to a daemon that isn't
listening typically succeeds locally. `onError` therefore surfaces only *local*
failures (network unreachable, message too large, bind/resolve failure) — never
"the daemon didn't receive it." This is inherent to UDP fire-and-forget.

## Scope

In: `UdpSender` only. Out: the `Sender` interface, `SegmentEncoder`,
`HttpApiSender`, datagram retry/buffering (remains fire-and-forget).
