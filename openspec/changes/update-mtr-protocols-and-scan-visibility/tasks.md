# Tasks: MTR protocol correctness, multi-protocol profiles, TCP diagnostics, Active Scans

Each numbered section is intended to land as its own PR through the
no-mistakes gate, in order. All fixtures are synthetic
(`192.0.2.0/24`, `198.51.100.0/24`, `2001:db8::/32`, `host01.example.com`).

## 1. Web-tier MTR dispatch (#4578)
- [ ] 1.1 `MtrAutomationDispatcher.candidate_agents/1`: build candidates from
  `AgentCommandBus.list_online_agents/0` (injectable `:session_lister` opt);
  adapt `session_to_candidate/1` to the session map shape.
- [ ] 1.2 `MtrRuntime.queue_trace/2`: map dispatcher error atoms to readable
  messages; rescue + log unexpected exceptions and return `{:error, msg}`.
- [ ] 1.3 Audit `ProcessRegistry` reads reachable from web-ng
  (`rg -n 'ProcessRegistry\.(select|lookup|find|list|count)'` over core modules
  web-ng calls) and route any found through RPC-safe helpers; record the audit
  result in the PR body.
- [ ] 1.4 Tests:
  - core: `dispatch_for_mode/5` with the registry absent and an injected
    session list (selects the preferred agent; returns
    `{:error, :no_candidate_agents}` on an empty list).
  - web-ng: `run_mtr` with an enabled policy and no registry shows a flash
    message and the LiveView survives.
  - Add rows to `INTEGRATION_SOURCE_DISPOSITIONS.tsv` for new core test files.
- [ ] 1.5 Verify on the lab deployment (where the crash reproduces): Queue MTR on a device
  page queues a trace; the web-ng logs have no `keys_Elixir.ServiceRadar.ProcessRegistry`
  error after the rollout finished.

## 2. TCP probing correctness (#4580)
- [ ] 2.1 `go/pkg/mtr/options.go`: add `TCPPort` (default 443) and
  `TCPSynRetries` (default 1, range 0..3); parse `tcp_port` and
  `tcp_syn_retries` in the checker, `mtr.run` and bulk payloads.
- [ ] 2.2 `socket.go`: build the TCP SYN (options: MSS) and compute the
  IPv4/IPv6 pseudo-header checksum; add a TCP segment parser that returns
  flags, ports, seq and ack.
- [ ] 2.3 `socket_linux.go`:
  - Send the crafted SYN on the raw socket with a controlled TTL/hop limit.
  - Reserve the source port by binding a TCP socket that is never listened on.
  - Add a raw `IPPROTO_TCP` receive socket, filtered to the target and flow.
  - Parse the quoted TCP seq from ICMP/ICMPv6 errors.
- [ ] 2.4 `tracer.go`:
  - Use a stable flow for TCP.
  - Probe key = TCP seq.
  - Match SYN-ACK/RST by `ack - 1`.
  - Set reached, and the target address on that hop, on a target SYN-ACK or
    RST.
  - Record the ICMP unreachable code per hop.
  - Return an error when zero probes were sent.
- [ ] 2.5 `socket_darwin.go`: connect-observe fallback (hold the socket for the
  probe timeout, `SO_LINGER 0` close, SYN-ACK = connected, RST = refused).
  Do not advertise `mtr_tcp_syn`.
- [ ] 2.6 `hop.go` / `TraceResult`: add `probed_hops`, `last_responding_hop`,
  `tcp_port` and `unreachable_code` (omitempty); keep the `total_hops`
  semantics.
- [ ] 2.7 Go tests (synthetic addresses only):
  - SYN build + checksum against known vectors.
  - TCP parser: SYN-ACK, RST and RST+ACK.
  - ICMP quote parsing of the TCP seq.
  - `matchProbeResponse` for each protocol.
  - `sendProbes` + `buildResult` with a fake socket, covering four cases:
    1. The target answers SYN-ACK at TTL 4: reached, 4 hops.
    2. The target answers RST: reached.
    3. No answer: `probed_hops` = MaxHops, `last_responding_hop` = last
       transit reply.
    4. Every send fails: error set.
  - Assert the stable 5-tuple across TTLs.
  - Update `go/pkg/mtr/BUILD.bazel`; `bazel test //go/pkg/mtr:mtr_test //go/pkg/agent:agent_test --config=remote`.
- [ ] 2.8 Integration test (`//go:build integration`, root): a TCP trace to a
  loopback listener reaches in 1 hop via SYN-ACK; a closed port reaches via
  RST.
- [ ] 2.9 Core ingest: derive `last_responding_hop` and `probed_hops` when the
  agent omits them; migration adds `mtr_traces.last_responding_hop`,
  `probed_hops`, `tcp_port` and `mtr_hops.unreachable_code` (nullable,
  `prefix: "platform"`).
- [ ] 2.10 UI:
  - The trace and device views state "reached in N hops" or
    "no reply past hop N (M probed)".
  - Collapse trailing all-loss hops.
  - Show the unreachable kind.
- [ ] 2.11 Docs: `docs/docs/mtr-protocols.md` explains:
  - why ICMP, UDP and TCP paths and depths differ (ECMP flow hashing,
    per-protocol filtering, rate limiting, firewall answer-on-behalf)
  - how to read `last_responding_hop` vs `probed_hops`
  - which TCP port to choose

  Link it from the MTR profile form.

## 3. TCP handshake diagnostics (#4581)
- [ ] 3.1 Engine destination phase (Linux): `ProbesPerHop` SYNs at the reached
  TTL (MaxHops if unreached), with `TCPSynRetries` retransmissions.
  - Count sent, SYN-ACK, RST, unanswered, retransmits, answered-after-retx,
    ack mismatches and duplicate SYN-ACKs.
  - Record handshake RTT min/avg/max.
  - Compute `tcp_server_response_us` per D5.
- [ ] 3.2 Per-hop reply counters (`reply_time_exceeded`, `reply_unreachable`,
  `reply_synack`, `reply_rst`) for all protocols; add them to `HopSnapshot`.
- [ ] 3.3 Agent: advertise the `mtr_tcp_syn` capability on Linux builds with a
  raw socket.
- [ ] 3.4 Migration: nullable columns.
  - `mtr_traces`: the D5 trace-level fields.
  - `mtr_hops`: the reply counters.

  Update the `MtrTrace` and `MtrHop` Ash resources and `MtrMetricsIngestor`
  row builders.
- [ ] 3.5 SRQL: add the columns to `rust/srql/src/schema.rs`, the
  `mtr_traces` / `mtr_hops` entities (filterable, and selectable in `stats:`),
  `integration_tests/srql/tests/fixtures/schema.sql` and the seed data; add
  parser/translate tests.
- [ ] 3.6 UI: a TCP handshake panel on the trace detail and device MTR tab
  (SYN / SYN-ACK / RST / drop % / retx / ack anomalies / handshake RTT /
  server response), with D5 definitions as tooltips; add per-hop reply-type
  columns to the hop table.
- [ ] 3.7 Tests:
  - Go: counters for each outcome.
  - Elixir: ingestor maps every field; null when absent (old agent).
  - Rust: SRQL filters.
  - web-ng: render test for the panel.

## 4. Multi-protocol MTR profiles (#4579)
- [ ] 4.1 Migration:
  - `mtr_policies.baseline_protocols text[] NOT NULL DEFAULT '{icmp}'`,
    backfilled from `baseline_protocol`; add `tcp_port integer NOT NULL
    DEFAULT 443`.
  - `mtr_bulk_job_targets.protocol text NOT NULL DEFAULT 'icmp'`; replace the
    unique index with `(command_id, target, protocol)`.
- [ ] 4.2 `MtrPolicy`:
  - `baseline_protocols` with atom items `[:icmp, :udp, :tcp]`,
    `min_length: 1`, canonical order and dedupe.
  - `tcp_port` constrained to 1..65535.
  - Stop writing `baseline_protocol`; update seeds and fixtures.
- [ ] 4.3 `AgentCommandBus.dispatch_bulk_mtr`:
  - Payload `protocols` + `tcp_port`, keeping `protocol` = the first entry.
  - Fan out one job per protocol for agents without `mtr_protocol_set`.
  - Bulk target rows keyed per protocol.
- [ ] 4.4 Agent bulk worker: when `protocols` is present, trace each target
  once per protocol on one worker slot; progress counts (target, protocol)
  units; per-target results carry `protocol`; advertise `mtr_protocol_set`.
- [ ] 4.5 `MtrAutomationDispatcher` and `MtrRuntime`: fan out one `mtr.run`
  per protocol; one cooldown window per target for the set.
- [ ] 4.6 `status_handler` / bulk result ingest: update bulk target rows by
  `(command_id, target, protocol)`.
- [ ] 4.7 Profile form (`settings/mtr_profiles_live`):
  - Protocol multi-select (the ICMP/UDP/TCP combinations).
  - TCP port input shown when TCP is selected.
  - Probe-volume multiplier hint.
  - Keep the existing ICMP-on-Kubernetes warning.
- [ ] 4.8 Interval guidance: scale the recommended interval by the protocol
  count until a multi-protocol run is measured.
- [ ] 4.9 Views: protocol filter on `/diagnostics/mtr`; the device MTR tab shows
  the latest trace per protocol side by side; the compare view warns when two
  traces use different protocols.
- [ ] 4.10 Update `openspec/changes/add-sweep-profile-mtr-mode/design.md` D4 to
  adopt the protocol set (`mtr_protocols`) instead of a single `mtr_protocol`.
- [ ] 4.11 Tests:
  - core: backfill migration; payload shape; fan-out for a legacy agent;
    per-protocol bulk target rows.
  - Go: a multi-protocol bulk job produces N traces per target.
  - web-ng: the form persists sets and validates non-empty.

## 5. MTR jobs in Active Scans (#4577)
- [ ] 5.1 `NetworksLive.Index.MtrJobs` loader: running and recent
  `mtr.bulk_run` commands, normalized to a shared scan-row shape with sweep
  executions.
- [ ] 5.2 Components:
  - an MTR running card (profile, agent, protocols, targets x protocols
    progress, rate, elapsed)
  - an MTR recent row (status, profile, started, duration, completed / failed
    / timed-out, reached count, link to `/diagnostics/mtr` for the job)
  - a Sweeps / MTR / All filter
  - MTR included in the Running badge and statistics cards
- [ ] 5.3 `Infos`: route `{:command_progress | :command_result, ...}` for
  `mtr.bulk_run` into MTR rows; the 15 s poll stays as the backstop.
- [ ] 5.4 Gate MTR rows and the filter on the `networks.sweeps.view`
  permission.
- [ ] 5.5 Tests:
  - loader normalisation
  - running -> completed transition via PubSub
  - permission gating
  - an existing sweep-only render is unchanged

## 6. Verification
- [ ] 6.1 `make test` (all unit shards) and `make lint` green before each PR.
- [ ] 6.2 `openspec validate update-mtr-protocols-and-scan-visibility --strict`.
- [ ] 6.3 Build and push images for the branch; roll the demo deployment (and
  the lab deployment for section 1).
- [ ] 6.4 Demo artefact checks. Only rows written after the rollout finished
  count. Record the rollout time first, and gate each check on
  `time > <rollout>`.
  - TCP baseline traces from the fixed agent have `target_reached = true` for
    targets ICMP reaches; for a reached target, `total_hops` equals the ICMP
    depth +/-1.
  - The TCP diagnostics columns are populated for Linux-agent traces.
  - A multi-protocol profile writes one trace per protocol per target.
  - Explicit failure branch: if zero post-rollout TCP rows exist, the check
    fails, not "pending".
- [ ] 6.5 Active Scans shows the running demo MTR bulk job and its completion.
- [ ] 6.6 Close #4577-#4581 with links to the merged PRs.
