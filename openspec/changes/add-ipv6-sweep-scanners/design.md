## Context

The current raw ICMP and SYN sweep paths assume IPv4 packet formats. IPv6 targets can be present in inventory, SRQL query results, and static sweep targets, so scanner routing must be explicit about IP family instead of treating all targets as IPv4-compatible.

The recent mitigation should prevent IPv6 targets from entering IPv4-only scanner paths. This change is the follow-up that makes ICMP and raw SYN scanning native for IPv6 rather than relying on TCP connect mode for IPv6 port checks.

## Goals

- Support IPv6 ICMP echo checks with the same operational semantics as IPv4 ICMP checks.
- Support high-performance raw SYN port checks for IPv6 targets.
- Keep one sweep group capable of scanning mixed IPv4 and IPv6 targets.
- Avoid materializing large IPv6 CIDR ranges accidentally; target compilation must remain bounded and observable.
- Preserve safe fallback behavior when raw socket privileges are unavailable.

## Non-Goals

- Replacing TCP connect scanning.
- Adding IPv6-specific UI controls beyond capability/status visibility needed for safe operation.
- Implementing exhaustive IPv6 network enumeration for broad prefixes. Large IPv6 CIDRs must remain bounded by existing target limits or explicit operator controls.
- Changing sweep result ingestion semantics in core beyond carrying correct protocol/family metadata.

## Scanner Design

### ICMPv6

ICMPv6 should use IPv6-aware sockets and packet types:

- Echo Request: type 128
- Echo Reply: type 129
- Destination Unreachable and Time Exceeded should be decoded as diagnostic failures where useful.

Response matching should include source address, ICMP identifier, sequence number, and execution context to avoid mixing concurrent probes. The scanner should expose metrics for sent packets, replies, timeouts, decode errors, and permission/fallback outcomes.

### Raw SYN over IPv6

The IPv6 SYN scanner should build IPv6 + TCP packets and compute TCP checksums over the IPv6 pseudo-header. Response decoding should classify at least:

- SYN-ACK as open
- RST as closed/reachable
- ICMPv6 unreachable as failed/reachable diagnostic when available
- timeout as unknown/unavailable

The existing bounded batch/streaming model should remain the execution shape. The implementation should avoid preallocating host x port slices for large scans and should reuse packet buffers where safe.

### Target Routing

Target routing should select scanner paths by parsed IP family and requested mode:

- IPv4 + ICMP -> IPv4 ICMP scanner
- IPv4 + TCP -> IPv4 raw SYN scanner
- IPv4 + TCP connect -> TCP connect scanner
- IPv6 + ICMP -> ICMPv6 scanner
- IPv6 + TCP -> IPv6 raw SYN scanner when capability is available, otherwise fallback according to profile/agent policy
- IPv6 + TCP connect -> TCP connect scanner

Scanner capability checks should happen before execution and should be visible in logs and metrics. Unsupported combinations should return explicit diagnostics, not repeated per-target warnings.

## Privilege and Fallback Policy

Raw ICMP/SYN scanners require network privileges such as `CAP_NET_RAW` or root depending on OS and deployment. The agent should detect capability at startup or scanner initialization and expose it in scanner diagnostics.

Fallback behavior:

- ICMPv6 has no equivalent TCP connect fallback; if ICMPv6 raw sockets are unavailable, the ICMPv6 portion should be skipped with a clear execution diagnostic.
- IPv6 TCP raw SYN may fall back to TCP connect when the sweep profile permits connect fallback or explicitly includes `tcp_connect`.
- Fallback must not double-count hosts or ports in execution metrics.

## Test Strategy

- Unit tests for IPv6 packet encoding, checksum calculation, and response classification.
- Target routing tests for mixed IPv4/IPv6 sweep modes.
- Integration-style tests using loopback IPv6 where available.
- Regression tests proving large IPv6 CIDRs are not expanded unintentionally.
- Agent tests for capability diagnostics when raw socket support is absent.
