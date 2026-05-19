# Change: Add native IPv6 sweep scanners

## Why

ServiceRadar can compile and route IPv6 sweep targets, but the high-performance ICMP and raw SYN scanner implementations are IPv4-only. Operators need first-class IPv6 discovery and availability checks without falling back to TCP connect-only behavior or emitting misleading "invalid IPv4 address" diagnostics.

## What Changes

- Add native ICMPv6 echo scanning to the agent sweeper, including correct packet type handling, response matching, timeout behavior, and metrics.
- Add native IPv6 raw TCP SYN scanning for port sweeps, with IPv6 packet construction, checksum handling, response decoding, and parity with existing bounded batch/stream execution.
- Route targets by IP family and scanner capability so IPv4 and IPv6 targets can coexist in one sweep group without cross-family warnings or silent drops.
- Preserve TCP connect as the unprivileged/fallback IPv6 port scan path when raw socket capabilities are unavailable or a profile explicitly selects connect mode.
- Add scanner metrics, logs, tests, and operator diagnostics that distinguish IPv4 ICMP/SYN, IPv6 ICMP/SYN, and TCP connect execution paths.

## Impact

- Affected specs: `sweeper`, `sweep-jobs`
- Affected code:
  - `go/pkg/scan` ICMP, TCP, and SYN scanner implementations
  - `go/pkg/sweeper` target generation, streaming, metrics, and result aggregation
  - `go/cmd/agent` scanner wiring and capability/privilege checks
  - sweep profile/config compilation tests and large-target regression tests
