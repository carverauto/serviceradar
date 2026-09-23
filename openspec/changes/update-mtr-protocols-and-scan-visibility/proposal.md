# Change: Correct TCP MTR, add multi-protocol profiles and TCP handshake diagnostics, and surface MTR jobs in Active Scans

## Why

Five open issues describe one underlying problem: MTR works well for ICMP and
poorly for everything around it.

- **#4580 (TCP hop counts).** Switching a profile from ICMP to TCP made traces
  longer. This is a defect, not a routing curiosity. The Linux TCP probe
  (`go/pkg/mtr/socket_linux.go` `SendTCP`) is a non-blocking kernel `connect()`
  closed as soon as the SYN leaves. The tracer only ever reads an ICMP socket,
  so the target's SYN-ACK or RST is never observed. `target_reached` can only
  become true if the target itself emits ICMP. Because the tracer's
  "stop at target" rules never fire, it records hops until the run's deadline
  or the consecutive-unknown cutoff. The resulting "hop count" measures the
  time budget, not the path. Every probe also uses a different destination port
  (`dstPort := seq`, 33434 and up), which puts each probe on a different 5-tuple.
  ECMP per-flow hashing can then route each TTL differently, and firewalls drop
  most of those ports. The live spec already says TCP reach is "detected via
  SYN-ACK or RST from the target address". The code does not implement it.
- **#4581 (TCP diagnostics).** Operators want cPacket-style handshake detail
  per hop and at the destination: SYNs sent, SYN-ACKs, SYN drop %, server RSTs,
  retransmissions, sequence anomalies, RTT and response time. Nothing in the
  engine distinguishes SYN-ACK from RST from no answer today, so none of this
  can be built until #4580 is fixed.
- **#4579 (multi-protocol profiles).** An MTR profile (`MtrPolicy`) carries a
  single `baseline_protocol`. Operators have to clone a profile to compare ICMP
  with TCP or UDP on the same target set. They want ICMP+TCP, ICMP+UDP,
  TCP+UDP and ICMP+UDP+TCP.
- **#4578 (Queue MTR crashes).** Clicking "Queue MTR" on a device page crashes
  the LiveView (`ArgumentError: ... keys_Elixir.ServiceRadar.ProcessRegistry`)
  whenever any MTR policy is enabled. `MtrAutomationDispatcher.candidate_agents/1`
  reads the Horde registry directly. web-ng deliberately does not join that
  registry (`join_process_registry: false`), so the ETS table does not exist
  there. The user sees the page reconnect and no error message.
- **#4577 (Active Scans).** The Network Sweeps page's Active Scans tab lists
  sweep executions only. MTR bulk jobs run on the same agents and on similar
  schedules, but they are invisible there. They are recorded only as
  `mtr.bulk_run` agent commands on `/diagnostics/mtr`.

## What Changes

### Web tier dispatch (#4578)
- `MtrAutomationDispatcher` SHALL resolve candidate agents through the
  RPC-safe `AgentCommandBus` session listing instead of `ProcessRegistry`,
  so policy-based dispatch works from nodes that are not registry members.
- The device page's Queue MTR path SHALL turn every dispatch failure into a
  flash message instead of crashing the LiveView.
- Add regression coverage that runs `dispatch_for_mode/5` with the registry
  absent.

### TCP probing correctness (#4580)
- **Linux TCP probes are crafted SYNs on a raw socket, and the tracer reads
  SYN-ACK and RST replies.** Replies are read on a raw `IPPROTO_TCP` socket.
  The probe is identified by the TCP sequence number, which ICMP Time Exceeded
  quotes in its first 8 transport bytes. A SYN-ACK or RST from the target
  marks the target reached at that TTL.
- **A TCP trace uses one destination port and one stable 5-tuple
  (Paris-traceroute style).** The port is configurable, default 443. Only TTL
  and sequence vary between probes, so ECMP keeps every TTL on the same path.
- **Hop semantics are explicit.** A trace records `last_responding_hop` and
  the probed depth separately. The UI reports "reached in N hops", or "no reply
  past hop N (M probed)", instead of a single ambiguous count.
- **Failures surface.**
  - The ICMP Destination Unreachable code is recorded on the hop that sent it,
    as the existing spec requires.
  - A trace in which no probe could be sent (for example, link-local IPv6
    without a zone) reports an error instead of a silent zero-hop result.
- **Non-Linux agents keep a connect-based TCP mode.** That mode observes the
  connect outcome to detect reach, and advertises that it cannot produce
  handshake diagnostics.
- **The expected ICMP/TCP/UDP differences are documented** under `docs/docs/`,
  so the remaining hop-count differences between protocols can be explained.

### TCP handshake diagnostics (#4581)
- **Per-hop reply counters:** Time Exceeded, Destination Unreachable (with
  code), SYN-ACK and RST.
- **Destination handshake summary** (trace level, TCP only):
  - SYNs sent, SYN-ACKs received, RSTs received and unanswered SYNs
  - SYN drop %
  - SYN retransmissions issued, and replies that arrived only after a
    retransmission
  - acknowledgement-number mismatches and duplicate SYN-ACKs (the
    active-probe analogue of sequence gaps)
  - handshake RTT min/avg/max
  - estimated server response time: destination handshake RTT minus the last
    transit hop's RTT, floored at zero
- **New nullable columns** carry these counters in `mtr_traces` and `mtr_hops`.
  Both Ash resources, the ingestor, SRQL (`in:mtr_traces`, `in:mtr_hops`) and
  the MTR trace and device views are updated to read them.

### Multi-protocol MTR profiles (#4579)
- **Replace `MtrPolicy.baseline_protocol` with `baseline_protocols`,** a
  non-empty set drawn from `icmp`/`udp`/`tcp`. A migration backfills it from
  the existing column, and the old column is dropped in a later change.
- **Profiles also carry `tcp_port`.** It applies whenever `tcp` is in the set.
- **One bulk job carries the whole set.** The bulk payload includes
  `protocols`, and agents advertising `mtr_protocol_set` run each target once
  per protocol inside one job. Each trace is tagged with its protocol. For
  older agents, core fans out one job per protocol.
- **Single-target dispatch fans out per protocol:** one `mtr.run` for each
  protocol in the set.
- **Protocol joins the bulk-target key.** `mtr_bulk_job_targets` gains
  `protocol`, and its unique key becomes `(command_id, target, protocol)`.
- **The profile form offers a protocol multi-select.** Trace views filter by
  protocol, and the device MTR tab shows the latest trace per protocol side by
  side.
- **Interval guidance scales with the protocol count.**

### MTR jobs in Active Scans (#4577)
- The Active Scans tab lists running and recent MTR bulk jobs alongside sweep
  executions. The two sources are normalized into one row shape, and a
  Sweeps / MTR / All filter selects between them.
- MTR rows show:
  - profile name, agent, protocol set, and start and duration
  - target progress: completed, failed and timed out
  - targets reached
  - a link to the job on `/diagnostics/mtr`
- MTR progress updates arrive on the `agent:commands` PubSub messages the tab
  already receives, which it currently discards.
- MTR rows are shown only to users who hold the `networks.sweeps.view`
  permission.

## Impact

- **Affected specs:**
  - `mtr-diagnostics`
    - MODIFIED: MTR Trace Execution; Multi-Protocol Probing; Managed Device
      Baseline Traces
    - ADDED: TCP SYN Probe Flow; TCP Handshake Diagnostics; Multi-Protocol
      MTR Profiles; Web-Tier MTR Dispatch
  - `sweep-jobs`
    - ADDED: MTR Jobs In Active Scans
- **Affected code:**
  - Go:
    - `go/pkg/mtr/` (tracer, options, hop, socket_linux, socket_darwin,
      socket)
    - `go/pkg/agent/` (mtr_bulk, control_stream, mtr_checker,
      push_loop_capabilities)
  - Elixir core:
    - `observability/mtr_policy.ex`, `mtr_trace.ex`, `mtr_hop.ex`,
      `mtr_metrics_ingestor.ex`, `mtr_automation_dispatcher.ex`,
      `mtr_baseline_scheduler.ex`
    - `edge/agent_command_bus.ex` and `agent_commands/status_handler.ex`
    - migrations
  - Rust: `rust/srql` (schema and the `mtr_traces` / `mtr_hops` entities,
    plus integration fixtures).
  - web-ng:
    - `settings/mtr_profiles_live`
    - `settings/networks_live` (Active Scans)
    - `diagnostics_live/mtr*`
    - `device_live/mtr_runtime.ex` and `mtr_components.ex`
- **Compatibility:**
  - Additive columns; no data rewrite beyond the policy backfill.
  - Old agents keep working. Core falls back to per-protocol fan-out, and TCP
    diagnostics stay null.
  - Agents running the fixed engine produce TCP traces with different, correct
    hop counts. A path-change alert may fire once per TCP-probed target when
    those agents roll out. This is called out in the release notes.
- **Coordination:**
  - `add-sweep-profile-mtr-mode` (pending, not started) plans a single
    `mtr_protocol` per sweep profile. It is expected to adopt the protocol set
    defined here, and its design note is updated to say so.
  - The ad-hoc scan (`add-adhoc-network-scan`) keeps its single
    `mtr_protocol`. Out of scope.
