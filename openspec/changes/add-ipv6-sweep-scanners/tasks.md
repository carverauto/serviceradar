## 1. Scanner Capability Audit
- [x] 1.1 Inventory current IPv4 ICMP, TCP connect, and raw SYN scanner interfaces and their result contracts.
- [x] 1.2 Identify shared packet encoding, response classification, metrics, and batching logic that can be reused without forcing IPv4 assumptions.
- [x] 1.3 Document runtime privilege requirements for Linux packages, containers, and systemd deployments.

## 2. ICMPv6 Scanner
- [x] 2.1 Implement ICMPv6 echo request packet construction and response parsing.
- [x] 2.2 Add concurrent probe matching by source address, identifier, sequence, and execution context.
- [x] 2.3 Add ICMPv6 scanner diagnostics for unavailable runtime capability.
- [x] 2.4 Add unit and loopback tests for successful reply, timeout, and decode/error cases.

## 3. IPv6 Raw SYN Scanner
- [x] 3.1 Implement IPv6 + TCP SYN packet construction with IPv6 pseudo-header checksum support.
- [x] 3.2 Decode IPv6 TCP and ICMPv6 responses into open, closed, unreachable, timeout, and error states.
- [x] 3.3 Preserve bounded streaming/batch execution for large target sets without materializing all host-port pairs.
- [x] 3.4 Add tests for packet encoding, response classification, retries, and rate metrics.

## 4. Target Routing and Fallback
- [x] 4.1 Route sweep targets by parsed IP family and requested sweep mode.
- [x] 4.2 Ensure mixed IPv4/IPv6 sweep groups execute each target on the correct scanner path.
- [x] 4.3 Add capability checks for raw IPv6 scanners and explicit diagnostics for unavailable modes.
- [x] 4.4 Implement fallback from IPv6 TCP mode to TCP connect without duplicate target/result accounting.

## 5. Config, Metrics, and Operator Visibility
- [x] 5.1 Update sweep profile/config handling to preserve mode intent while reporting effective scanner execution paths.
- [x] 5.2 Add protocol/family labels to scanner metrics and logs.
- [x] 5.3 Surface execution diagnostics for skipped or fallback IPv6 scanner paths.

## 6. Regression and Release Validation
- [x] 6.1 Add regression tests proving broad IPv6 CIDRs are not expanded accidentally.
- [x] 6.2 Add focused Go tests for `go/pkg/scan`, `go/pkg/sweeper`, and `go/cmd/agent`.
- [x] 6.3 Add a documented manual validation path using an IPv6 loopback target and a reachable IPv6 host.
- [x] 6.4 Verify package/container manifests still grant the capabilities required for raw scanners.
