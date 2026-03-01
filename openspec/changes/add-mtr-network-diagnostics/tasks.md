## 1. Core MTR Library

- [ ] 1.1 Create `go/pkg/mtr/options.go` — Configuration types (Options, Protocol enum, defaults)
- [ ] 1.2 Create `go/pkg/mtr/hop.go` — HopResult struct with running statistics (Welford's algorithm for mean/variance, jitter tracking, sample ring buffer)
- [ ] 1.3 Create `go/pkg/mtr/probe.go` — Probe types (ICMP, UDP, TCP), packet construction, sequence management
- [ ] 1.4 Create `go/pkg/mtr/socket.go` — Socket abstraction interface
- [ ] 1.5 Create `go/pkg/mtr/socket_linux.go` — Linux raw socket + SOCK_DGRAM fallback implementation
- [ ] 1.6 Create `go/pkg/mtr/socket_darwin.go` — macOS raw socket implementation
- [ ] 1.7 Create `go/pkg/mtr/tracer.go` — Core tracer: probe send loop, ICMP response listener, probe matching, hop statistics update, termination logic
- [ ] 1.8 Create `go/pkg/mtr/dns.go` — Async DNS resolver with goroutine pool and TTL cache

## 2. ICMP Probe Implementation

- [ ] 2.1 Implement ICMP Echo Request construction (IPv4 + IPv6)
- [ ] 2.2 Implement ICMP response parsing — Time Exceeded, Echo Reply, Destination Unreachable
- [ ] 2.3 Implement probe matching by ICMP ID + Sequence from inner packet headers
- [ ] 2.4 Implement RTT calculation with microsecond precision
- [ ] 2.5 Implement ECMP detection (multiple responding IPs per hop)

## 3. UDP/TCP Probe Implementation

- [ ] 3.1 Implement UDP probe construction with port-based sequence encoding
- [ ] 3.2 Implement TCP SYN probe via non-blocking connect with TTL control
- [ ] 3.3 Implement response matching for UDP (ICMP Port Unreachable) and TCP (RST/SYN-ACK)

## 4. Statistics Engine

- [ ] 4.1 Implement Welford's online algorithm for mean and variance
- [ ] 4.2 Implement jitter calculation (instantaneous, average, worst, RFC 1889 interarrival)
- [ ] 4.3 Implement loss percentage with in-flight probe exclusion
- [ ] 4.4 Implement sample ring buffer (last 200 RTTs per hop)
- [ ] 4.5 Unit tests for statistics calculations against known values

## 5. Proto Definitions

- [ ] 5.1 Add `MtrHopResult` message to `monitoring.proto` (hop number, address, hostname, loss%, sent, received, last/avg/min/max/stddev latency, jitter)
- [ ] 5.2 Add `MtrTraceResult` message (target, hops list, total hops, timestamp, protocol, agent/gateway IDs)
- [ ] 5.3 Regenerate proto Go bindings

## 6. Agent Integration

- [ ] 6.1 Add MTR check type handling in `push_loop.go` (scheduling, result collection, config parsing)
- [ ] 6.2 Add MTR response types to agent models (MtrResponse, MtrHopResponse)
- [ ] 6.3 Add `mtr.run` command handler in `control_stream.go` for on-demand traces
- [ ] 6.4 Wire MTR check config through `AgentCheckConfig.settings` parsing

## 7. Testing

- [ ] 7.1 Unit tests for packet construction and parsing (ICMP, UDP, TCP)
- [ ] 7.2 Unit tests for probe matching and sequence management
- [ ] 7.3 Unit tests for hop statistics (known RTT sequences → expected mean/stddev/jitter)
- [ ] 7.4 Integration test: localhost loopback trace (single hop, verifiable)
- [ ] 7.5 Integration test: agent config parsing and check registration

## 8. Documentation & Build

- [ ] 8.1 Add BUILD.bazel for `go/pkg/mtr/` package
- [ ] 8.2 Update agent configuration documentation with MTR check type examples
- [ ] 8.3 Add MTR capability to agent feature list in deployment docs
