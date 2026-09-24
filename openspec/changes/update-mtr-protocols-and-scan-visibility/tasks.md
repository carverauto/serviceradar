# Tasks: MTR protocol correctness, multi-protocol profiles, TCP diagnostics, Active Scans

Each numbered section is intended to land as its own PR through the
no-mistakes gate, in order. All fixtures are synthetic
(`192.0.2.0/24`, `198.51.100.0/24`, `2001:db8::/32`, `host01.example.com`).

## 1. Web-tier MTR dispatch (#4578)
- [x] 1.1 `MtrAutomationDispatcher.candidate_agents/1`: build candidates from
  `AgentCommandBus.list_online_agents/0` (injectable `:session_lister` opt);
  adapt `session_to_candidate/1` to the session map shape.
- [x] 1.2 `MtrRuntime.queue_trace/2`: map dispatcher error atoms to readable
  messages; rescue + log unexpected exceptions and return `{:error, msg}`.
  - Shipped as `queue_trace/3` (collaborators injectable for tests) plus
    `dispatch_error_message/1`; exits are caught as well as exceptions. A
    policy that cannot dispatch still falls back to the first connected agent
    (Queue MTR is an operator request), and its reason is appended to the error
    when that fallback fails too. `{:window_persist_failed, _}` ends the attempt
    as queued, so the trace is not dispatched twice. The dispatcher now returns
    `{:error, :out_of_scope}` for a scope mismatch instead of `{:error, false}`.
- [x] 1.3 Audit `ProcessRegistry` reads reachable from web-ng
  (`rg -n 'ProcessRegistry\.(select|lookup|find|list|count)'` over core modules
  web-ng calls) and route any found through RPC-safe helpers; record the audit
  result in the PR body.
  - Audit (recorded here as well as in the PR body):
    - Guarded: `GatewayRegistry` and `AgentRegistry` `lookup`/`find_*`/`count`
      go through `via_registry/3` (local read on members, RPC to a core node
      otherwise, rescue to a default). `AgentCommandBus` control-session reads
      check `registry_present?/0` and fall back to `registry_rpc/2`.
      `RateLimiter.peer_pids/0` and its self-registration cleanup check
      `Process.whereis/1` first, and `peer_pids/0` rescues `ArgumentError`.
      `RemoteAccessBrokerRegistry` checks `Process.whereis/1` too.
    - Fixed: `GatewayRegistry.find_available_gateways/0` read the registry
      directly. web-ng runs the `:service_checks` Oban queue, where the
      `PollingSchedule` `:execute` trigger calls `PollOrchestrator`, which
      reads it. It now uses `via_registry/3`
      (`test/serviceradar/registry/gateway_registry_registry_absent_test.exs`).
    - Unguarded, not reachable from web-ng: `DeviceRegistry` `lookup`,
      `list_devices` and `count`, and `StatefulAlertEngine.lookup_engine/1`.
      web-ng does not call either module. Their callers are core actors,
      EventWriter processors and Oban workers on `:maintenance` and
      `:monitoring`. web-ng runs `:maintenance` only when its limit is raised
      from the default 0, and never runs `:monitoring`.
- [x] 1.4 Tests:
  - core: `dispatch_for_mode/5` with the registry absent and an injected
    session list (selects the preferred agent; returns
    `{:error, :no_candidates}` on an empty list).
    - The error atom is `:no_candidates`, not `:no_candidate_agents`. A
      non-empty listing is covered through `dispatch_for_mode/5` up to
      preferred-agent selection (`:preferred_agent_unavailable`). The successful
      selection is covered through `select_agents/4` (public, `@doc false`),
      because the cooldown read and dispatch-window write after it need the
      database.
  - web-ng: `run_mtr` with an enabled policy and no registry shows a flash
    message and the LiveView survives.
    - Covered at `MtrRuntime.queue_trace/3`
      (`test/phoenix/live/device_live/mtr_runtime_test.exs`, db_free), not by
      mounting the LiveView, which needs the database. The test uses the real
      dispatcher and command bus with no registry and asserts the readable
      message. `run_mtr` puts any `{:error, message}` in the flash.
  - Add rows to `INTEGRATION_SOURCE_DISPOSITIONS.tsv` for new core test files.
- [ ] 1.5 Verify on the lab deployment (where the crash reproduces): Queue MTR on a device
  page queues a trace; the web-ng logs have no `keys_Elixir.ServiceRadar.ProcessRegistry`
  error after the rollout finished.

## 2. TCP probing correctness (#4580)
- [x] 2.1 `go/pkg/mtr/options.go`: add `TCPPort` (default 443) and
  `TCPSynRetries` (default 1, range 0..3); parse `tcp_port` and
  `tcp_syn_retries` in the checker, `mtr.run` and bulk payloads.
- [x] 2.2 `socket.go`: build the TCP SYN (options: MSS) and compute the
  IPv4/IPv6 pseudo-header checksum; add a TCP segment parser that returns
  flags, ports, seq and ack.
  - The parser returns ports, ack and flags. A reply is matched by
    `ack - 1`, so the received seq is not needed.
- [x] 2.3 `socket_linux.go`:
  - Send the crafted SYN on the raw socket with a controlled TTL/hop limit.
  - Reserve the source port by binding a TCP socket that is never listened on.
  - Add a raw `IPPROTO_TCP` receive socket, filtered to the target and flow.
  - Parse the quoted TCP seq from ICMP/ICMPv6 errors.
  - Shipped in `tcp_flow_raw_linux.go`. One BPF-filtered raw `IPPROTO_TCP`
    socket both sends and receives. `socket_linux.go` only opens that flow.
    The quoted seq is parsed in `socket.go` (`parseQuotedTransport`).
- [x] 2.4 `tracer.go`:
  - Use a stable flow for TCP.
  - Probe key = TCP seq.
  - Match SYN-ACK/RST by `ack - 1`.
  - Set reached, and the target address on that hop, on a target SYN-ACK or
    RST.
  - Record the ICMP unreachable code per hop.
  - Return an error when zero probes were sent.
- [x] 2.5 `socket_darwin.go`: connect-observe fallback (hold the socket for the
  probe timeout, `SO_LINGER 0` close, SYN-ACK = connected, RST = refused).
  Do not advertise `mtr_tcp_syn`.
  - Shipped in `tcp_flow_connect.go`, which every platform uses when no raw
    TCP socket is available. It is not specific to darwin.
- [x] 2.6 `hop.go` / `TraceResult`: add `probed_hops`, `last_responding_hop`,
  `tcp_port` and `unreachable_code` (omitempty); keep the `total_hops`
  semantics.
- [x] 2.7 Go tests (synthetic addresses only):
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
  - Checksums are pinned to hand-worked RFC 1071 values (IPv4 `0x755c`, IPv6
    `0x062d`, plus the RFC 1071 section 3 example). `matchProbeResponse` has
    ICMP, ICMPv6 and UDP cases in `match_probe_test.go`. The 5-tuple is pinned
    twice: the tracer opens one flow and sends every TTL on it, and the raw
    flow's SYNs differ only in seq and checksum.
- [x] 2.8 Integration test (`//go:build integration`, root): a TCP trace to a
  loopback listener reaches in 1 hop via SYN-ACK; a closed port reaches via
  RST.
  - In `tracer_integration_test.go`. It skips unless run as root and fails on
    any error after that. `go vet -tags integration` passes, but no CI lane
    runs it and it has not run as root yet.
- [x] 2.9 Core ingest: derive `last_responding_hop` and `probed_hops` when the
  agent omits them; migration adds `mtr_traces.last_responding_hop`,
  `probed_hops`, `tcp_port` and `mtr_hops.unreachable_code` (nullable,
  `prefix: "platform"`).
- [x] 2.10 UI:
  - The trace and device views state "reached in N hops" or
    "no reply past hop N (M probed)".
  - Collapse trailing all-loss hops.
  - Show the unreachable kind.
- [x] 2.11 Docs: `docs/docs/mtr-protocols.md` explains:
  - why ICMP, UDP and TCP paths and depths differ (ECMP flow hashing,
    per-protocol filtering, rate limiting, firewall answer-on-behalf)
  - how to read `last_responding_hop` vs `probed_hops`
  - which TCP port to choose

  Link it from the MTR profile form.

## 3. TCP handshake diagnostics (#4581)
- [x] 3.1 Engine destination phase (Linux): `ProbesPerHop` SYNs at the reached
  TTL (MaxHops if unreached), with `TCPSynRetries` retransmissions.
  - Count sent, SYN-ACK, RST, unanswered, retransmits, answered-after-retx,
    ack mismatches and duplicate SYN-ACKs.
  - Record handshake RTT min/avg/max.
  - Compute `tcp_server_response_us` per D5.
  - Path probing keeps 30% of a deadline-bound trace's remaining budget
    (capped at (1 + retries) probe timeouts) for this phase, and each round
    waits at most its share of what is left, so the fast bulk profile still
    measures the handshake.
- [x] 3.2 Per-hop reply counters (`reply_time_exceeded`, `reply_unreachable`,
  `reply_synack`, `reply_rst`) for all protocols; add them to `HopSnapshot`.
- [x] 3.3 Agent: advertise the `mtr_tcp_syn` capability on Linux builds with a
  raw socket (probed each time capabilities are computed, by opening one); parse `tcp_syn_retries`
  (0..3) in check settings, `mtr.run` and bulk payloads.
- [x] 3.4 Migration: nullable columns.
  - `mtr_traces`: the D5 trace-level fields.
  - `mtr_hops`: the reply counters.

  Update the `MtrTrace` and `MtrHop` Ash resources and `MtrMetricsIngestor`
  row builders.
- [x] 3.5 SRQL: add the columns to `rust/srql/src/schema.rs`, the
  `mtr_traces` / `mtr_hops` entities (filterable, and selectable in `stats:`),
  `integration_tests/srql/tests/fixtures/schema.sql` and the seed data; add
  parser/translate tests.
- [x] 3.6 UI: a TCP handshake panel on the trace detail and device MTR tab
  (SYN / SYN-ACK / RST / drop % / retx / ack anomalies / handshake RTT /
  server response), with D5 definitions as tooltips; add per-hop reply-type
  columns to the hop table.
  - Shipped as a single "Replies" column rendered by
    `MtrHandshake.reply_summary/1`, not one column per reply type.
- [x] 3.7 Tests:
  - Go: counters for each outcome.
  - Elixir: ingestor maps every field; null when absent (old agent).
  - Rust: SRQL filters.
  - web-ng: render test for the panel.

## 4. Multi-protocol MTR profiles (#4579)
- [x] 4.1 Migration:
  - `mtr_policies.baseline_protocols text[] NOT NULL DEFAULT '{icmp}'`,
    backfilled from `baseline_protocol`; add `tcp_port integer NOT NULL
    DEFAULT 443`.
  - `mtr_bulk_job_targets.protocol text NOT NULL DEFAULT 'icmp'`; replace the
    unique index with `(command_id, target, protocol)`.
- [x] 4.2 `MtrPolicy`:
  - `baseline_protocols` with atom items `[:icmp, :udp, :tcp]`,
    `min_length: 1`, canonical order and dedupe.
  - `tcp_port` constrained to 1..65535.
  - `baseline_protocol` is kept in step with the first protocol (for
    rollback and callers that still set it) instead of being dropped.
- [x] 4.3 `AgentCommandBus.dispatch_bulk_mtr`:
  - Payload `protocols` + `tcp_port`, keeping `protocol` = the first entry.
  - Agents without `mtr_protocol_set` get the first protocol only (an agent
    runs one bulk job at a time, so per-protocol fan-out would be rejected);
    capability is checked before the command is created.
  - Bulk target rows keyed per protocol.
- [x] 4.4 Agent bulk worker: when `protocols` is present, trace each target
  once per protocol on one worker slot; progress counts (target, protocol)
  units; per-target results carry `protocol`; advertise `mtr_protocol_set`.
- [x] 4.5 `MtrAutomationDispatcher` and `MtrRuntime`: baseline fans out one
  `mtr.run` per protocol; incident and recovery use the first protocol only
  (consensus keeps one outcome per agent); one cooldown window per target for
  the set.
- [x] 4.6 `status_handler` / bulk result ingest: update bulk target rows by
  `(command_id, target, protocol)`.
- [x] 4.7 Profile form (`settings/mtr_profiles_live`):
  - Protocol multi-select (the ICMP/UDP/TCP combinations).
  - TCP port input shown when TCP is selected.
  - Probe-volume multiplier hint.
  - Keep the existing ICMP-on-Kubernetes warning.
- [x] 4.8 Interval guidance: scale the recommended interval by the protocol
  count until a multi-protocol run is measured.
- [x] 4.9 Views: the device MTR tab shows the latest trace per protocol; the
  compare view warns when two traces use different protocols.
  `/diagnostics/mtr` already filters by protocol through its SRQL box
  (`protocol:tcp`), so no separate control was added.
- [x] 4.10 Update `openspec/changes/add-sweep-profile-mtr-mode/design.md` D4 to
  adopt the protocol set (`mtr_protocols`) instead of a single `mtr_protocol`.
  - D5 there still said "MTR protocol" (singular) for the UI inputs. That is
    now "MTR protocols". Its `tasks.md`, `proposal.md` and spec scenario still
    use the singular.
- [x] 4.11 Tests:
  - core: payload shape and per-protocol bulk target rows and updates
    (integration), first-protocol fallback for a legacy agent, protocol helpers.
  - Go: protocol parsing, unit expansion, protocol on target updates.
  - web-ng: form protocol parsing (empty selection rejected), labels, device
    latest-by-protocol, compare warning (db_free).

## 5. MTR jobs in Active Scans (#4577)
- [x] 5.1 `NetworksLive.Index.MtrJobs` loader: running and recent
  `mtr.bulk_run` commands, normalized to a shared scan-row shape with sweep
  executions.
- [x] 5.2 Components:
  - an MTR running card (profile, agent, protocols, started, status,
    trace progress counted in targets x protocols)
  - an MTR recent row (status, profile, started, duration, completed / failed
    / timed-out, reached count reported by the agent, link to
    `/diagnostics/mtr` filtered by the job's agent)
  - a Sweeps / MTR / All filter
  - MTR included in the Running badge; the sweep statistics cards stay
    sweep-only and hide under the MTR filter
- [x] 5.3 `Infos`: `{:command_progress | :command_result, ...}` for
  `mtr.bulk_run` schedule a debounced (1 s) reload of the MTR rows; the 15 s
  poll stays as the backstop.
- [x] 5.4 Gate MTR rows and the filter on the `networks.sweeps.view`
  permission.
- [x] 5.5 Tests (db_free):
  - loader normalisation (running, finished with reached count, manual,
    legacy single protocol) and status mapping
  - the Sweeps / MTR / All filter
  - permission gating, including a forbidden `AgentCommand` read
  - a zero `reached_targets` renders `0`, distinct from a missing one
  - sweep sections render unchanged without MTR permission
  - Go: the reached-target predicate, and a zero `reached_targets` being
    serialized

## 6. Verification
- [ ] 6.1 `make test` (all unit shards) and `make lint` green before each PR.
- [x] 6.2 `openspec validate update-mtr-protocols-and-scan-visibility --strict`.
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
