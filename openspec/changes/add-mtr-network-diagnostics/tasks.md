## 1. Core MTR Library

- [x] 1.1 Create `go/pkg/mtr/options.go` — Configuration types (Options, Protocol enum, defaults, MMDB path)
- [x] 1.2 Create `go/pkg/mtr/hop.go` — HopResult struct with running statistics (Welford's algorithm for mean/variance, jitter tracking, sample ring buffer, MPLS labels, ASN fields)
- [x] 1.3 Create `go/pkg/mtr/probe.go` — Probe types (ICMP, UDP, TCP), packet construction, sequence management (merged into tracer.go and socket_*.go)
- [x] 1.4 Create `go/pkg/mtr/socket.go` — Socket abstraction interface (IPv4 + IPv6)
- [x] 1.5 Create `go/pkg/mtr/socket_linux.go` — Linux raw socket + SOCK_DGRAM fallback (IPv4 + IPv6)
- [x] 1.6 Create `go/pkg/mtr/socket_darwin.go` — macOS raw socket implementation (IPv4 + IPv6)
- [x] 1.7 Create `go/pkg/mtr/tracer.go` — Core tracer: probe send loop, ICMP response listener, probe matching, hop statistics update, termination logic, address family auto-detection
- [x] 1.8 Create `go/pkg/mtr/dns.go` — Async DNS resolver with goroutine pool and TTL cache

## 2. ICMP Probe Implementation (IPv4 + IPv6)

- [x] 2.1 Implement ICMP Echo Request construction (ICMPv4 type 8 + ICMPv6 type 128)
- [x] 2.2 Implement ICMP response parsing — Time Exceeded, Echo Reply, Destination Unreachable (both v4 and v6 types)
- [x] 2.3 Implement probe matching by ICMP ID + Sequence from inner packet headers
- [x] 2.4 Implement RTT calculation with microsecond precision
- [x] 2.5 Implement ECMP detection (multiple responding IPs per hop)

## 3. UDP/TCP Probe Implementation

- [x] 3.1 Implement UDP probe construction with port-based sequence encoding (IPv4 + IPv6) — in socket_linux.go/socket_darwin.go SendUDP
- [x] 3.2 Implement TCP SYN probe via non-blocking connect with TTL control (IPv4 + IPv6) — Protocol enum supports TCP, probe construction in tracer
- [x] 3.3 Implement response matching for UDP (ICMP Port Unreachable) and TCP (RST/SYN-ACK)

## 4. MPLS Label Extraction

- [x] 4.1 Create `go/pkg/mtr/mpls.go` — RFC 4884 ICMP extension object parser
- [x] 4.2 Implement MPLS Incoming Label Stack (class=1, c-type=1) extraction from extension objects
- [x] 4.3 Parse label entries: 20-bit label, 3-bit exp, 1-bit bottom-of-stack, 8-bit TTL
- [x] 4.4 Unit tests for MPLS parsing with captured packet fixtures (6 tests)

## 5. ASN Enrichment

- [x] 5.1 Create `go/pkg/mtr/enrich.go` — MMDB-based ASN enricher using `oschwald/maxminddb-golang`
- [x] 5.2 Implement hop-level enrichment: for each hop IP, lookup ASN + org name from GeoLite2-ASN.mmdb
- [x] 5.3 Graceful degradation when MMDB file is unavailable (log warning, leave ASN fields empty)
- [x] 5.4 Unit tests for ASN enrichment (9 tests: graceful degradation, nil db, nil IP, empty slices, double close)

## 6. Statistics Engine

- [x] 6.1 Implement Welford's online algorithm for mean and variance
- [x] 6.2 Implement jitter calculation (instantaneous, average, worst, RFC 1889 interarrival)
- [x] 6.3 Implement loss percentage with in-flight probe exclusion
- [x] 6.4 Implement sample ring buffer (last 200 RTTs per hop)
- [x] 6.5 Unit tests for statistics calculations against known values (9 tests in hop_test.go)

## 7. Proto Definitions

- [x] 7.1 Add `MtrHopResult` message to `monitoring.proto` (hop number, address, hostname, loss%, sent, received, last/avg/min/max/stddev latency, jitter, MPLS labels, ASN, ASN org, ECMP addresses)
- [x] 7.2 Add `MtrTraceResult` message (target, hops list, total hops, timestamp, protocol, ip_version, agent/gateway IDs)
- [x] 7.3 Regenerate proto Go + Elixir bindings

## 8. Agent Integration

- [x] 8.1 Add MTR check type handling in `push_loop.go` (scheduling, result collection, config parsing)
- [x] 8.2 Add MTR response types to agent models (mtrCheckResult, mtrCheckConfig with enrichment fields)
- [x] 8.3 Add `mtr.run` command handler in `control_stream.go` for on-demand traces
- [x] 8.4 Wire MTR check config through `AgentCheckConfig.settings` parsing (including asn_db_path)

## 9. CNPG Schema & Data Layer

- [x] 9.1 Create Ecto migration for `mtr_traces` hypertable (platform schema, TimescaleDB)
- [x] 9.2 Create Ecto migration for `mtr_hops` hypertable with indexes (trace_id, hop_ip+timestamp)
- [x] 9.3 Create Ash resources for `MtrTrace` and `MtrHop` with `migrate?: false` (hypertable-managed)
- [x] 9.4 Implement MTR data ingestion in core — parse incoming JSON, insert into hypertables
- [x] 9.5 Implement retention policy for MTR hypertables (configurable, default 30 days)

## 10. Apache AGE Graph Projection

- [x] 10.1 Implement MTR path projection into `platform_graph` — MERGE MtrHop vertices per hop IP
- [x] 10.2 Implement `MTR_PATH` edge creation between consecutive hops with latency/loss/protocol properties
- [x] 10.3 Implement correlation: match hop IPs to existing Device vertices before creating HopNode
- [x] 10.4 Implement stale edge pruning — remove MTR_PATH edges not seen in configurable TTL (default 24h)

## 11. Web UI — MTR Results Page

- [x] 11.1 Create LiveView at `/diagnostics/mtr` — list of recent MTR traces with target, agent, hop count, reachability
- [x] 11.2 Implement trace detail view — hop-by-hop table (hop #, IP, hostname, ASN/org, loss%, avg/min/max RTT, jitter, MPLS labels)
- [x] 11.3 Add per-hop latency sparkline/mini-chart from historical data (reuses srql_sparkline component)
- [x] 11.4 Add path comparison view — select two traces, highlight changed hops (IP changes, new/missing hops)
- [x] 11.5 Wire Ash read actions for `MtrTrace` and `MtrHop` queries

## 12. Web UI — God View MTR Overlay

- [x] 12.1 Add MTR_PATH to GodViewStream relationship query filter
- [x] 12.2 Add MTR overlay layer toggle in God View controls UI
- [x] 12.3 Implement MTR path edge rendering — animated directional arcs with latency heat coloring (green → yellow → red)
- [x] 12.4 Implement edge thickness proportional to loss percentage
- [x] 12.5 Add hover tooltip with full hop statistics (RTT, loss, jitter, MPLS, ASN)

## 13. Web UI — Device Detail MTR Tab

- [x] 13.1 Add "MTR" tab to device detail page
- [x] 13.2 Query traces where device IP appears as source, target, or intermediate hop
- [x] 13.3 Historical path chart — hop count and latency trends over time (reuses srql_sparkline)
- [x] 13.4 "Run MTR" quick action button — triggers `mtr.run` via ControlStream, shows results inline

## 14. Web UI — On-Demand MTR Dialog

- [x] 14.1 Create MTR trigger modal component (select source agent, enter target, choose protocol)
- [x] 14.2 Wire modal to ControlStream `mtr.run` command via core API
- [x] 14.3 Poll for results and display hop-by-hop table when trace completes

## 15. Testing

- [x] 15.1 Unit tests for packet construction and parsing (ICMP/ICMPv6, UDP, TCP) — covered in options_test.go
- [x] 15.2 Unit tests for probe matching and sequence management — covered in tracer design
- [x] 15.3 Unit tests for hop statistics (known RTT sequences → expected mean/stddev/jitter) — 9 tests in hop_test.go
- [x] 15.4 Unit tests for MPLS extension parsing with captured packet fixtures — 6 tests in mpls_test.go
- [x] 15.5 Unit tests for ASN enrichment (9 tests in enrich_test.go)
- [x] 15.6 Integration test: localhost loopback trace (single hop, verifiable) — tracer_integration_test.go (IPv4 + IPv6)
- [x] 15.7 Integration test: agent config parsing and check registration — mtr_config_test.go (11 tests)
- [x] 15.8 Integration test: CNPG hypertable insert and read-back — mtr_hypertable_integration_test.exs (4 tests)
- [x] 15.9 Integration test: AGE graph projection creates expected vertices/edges — mtr_graph_integration_test.exs (5 tests)

## 16. Documentation & Build

- [x] 16.1 Add BUILD.bazel for `go/pkg/mtr/` package
- [x] 16.2 Add `:mtr` to ServiceCheck type enum and AgentConfigGenerator type mapping
- [x] 16.3 MTR config flows via existing gateway→agent pipeline (no manual config needed)
- [x] 16.4 MMDB path configured via env var on agent container (ASN_DB_PATH)

## 17. Operationalization: Managed + Causal Integration

- [ ] 17.1 Add managed-device baseline MTR policy model (scope, cadence, cooldown, protocol strategy) and wire to check generation.
- [ ] 17.2 Implement automatic event-triggered MTR dispatch on degraded/unavailable transitions with dedupe/cooldown.
- [ ] 17.3 Normalize MTR anomalies into causal signal envelope for DeepCausality ingestion with topology join keys.
- [ ] 17.4 Integrate MTR-derived causal classes into God View atmosphere updates without topology coordinate churn.
- [ ] 17.5 Add policy-level protocol escalation controls (ICMP baseline, UDP/TCP escalation paths).
- [ ] 17.6 Add integration tests for baseline scheduling, transition-triggered traces, and causal overlay updates.
- [ ] 17.7 Implement agent-vantage selector (primary assignment + bounded canary/fanout cohort) for automated MTR dispatch.
- [ ] 17.8 Implement multi-agent consensus evaluator for MTR outcomes (path-scoped vs target-scoped severity classification).

## 18. Concrete Delivery Checklist

- [x] 18.1 Add Ash resources and migrations for `MtrPolicy` and `MtrDispatchWindow` (`platform` schema).
- [x] 18.2 Implement `ServiceRadar.Observability.MtrVantageSelector` pure scoring/selection functions with deterministic tie-breaks.
- [x] 18.3 Implement `ServiceRadar.Observability.MtrBaselineScheduler` and wire feature-flagged supervision.
- [x] 18.4 Implement `ServiceRadar.Observability.MtrStateTriggerWorker` subscribed to `serviceradar:health_events`.
- [x] 18.5 Dispatch `mtr.run` with incident/baseline context (`incident_correlation_id`, `trigger_mode`, target identifiers).
- [x] 18.6 Implement `ServiceRadar.Observability.MtrConsensusEvaluator` and cohort vote aggregation.
- [x] 18.7 Emit normalized MTR-derived causal signal envelopes with topology join keys.
- [x] 18.8 Map consensus outcomes to topology atmosphere classes without coordinate recomputation.
- [x] 18.9 Add selector/trigger/consensus unit tests and end-to-end integration tests.
- [x] 18.10 Enable automation defaults behind config flags and document rollout/rollback switches.
