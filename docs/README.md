# Documentation

Design and architecture references for `aws_xray_sdk`.

## Contents

- [`architecture.md`](architecture.md) — architecture overview: components, data
  flow (standalone and Lambda), HTTP tracing, double-trace suppression, sampling,
  and the runtime entity model.
- [`udp-sender-robustness.md`](udp-sender-robustness.md) — design note on how
  `UdpSender` resolves the daemon address, binds its socket, and guarantees the
  transport never faults the traced operation.

For usage, the public API reference, and examples, see the
[top-level README](../README.md) and the [`example/`](../example) directory.
