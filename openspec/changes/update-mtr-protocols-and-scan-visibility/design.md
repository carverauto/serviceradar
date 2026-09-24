## Context

The MTR engine is pure Go in `go/pkg/mtr`. One `Tracer` runs one protocol
against one target, walking TTL 1..MaxHops for `ProbesPerHop` cycles. Replies
are read from a single ICMP socket and matched to probes by ICMP sequence, or
for UDP/TCP by the quoted inner destination port.

**Observed behaviour after a baseline profile switched from ICMP to TCP.** On
the demo deployment:
- Targets that ICMP reaches (a few hops on the LAN; under ten hops for a public
  anycast service) were never marked reached over TCP.
- Intermediate routers answered the TCP probes with Time Exceeded for the first
  few TTLs, then nothing, and every trace was padded to the bulk profile's
  MaxHops.
- TCP traces to link-local IPv6 targets returned zero hops and no error.

Code reading explains all three:

1. **Replies from the target are never read.** `SendTCP` opens a
   `SOCK_STREAM` socket, sets TTL, issues a non-blocking `connect()`, and
   `defer`-closes the socket. The SYN leaves. If a SYN-ACK or RST comes back,
   the kernel handles it on a socket that no longer exists. The tracer only
   listens on ICMP. `target_reached` is therefore set only when the target
   happens to send ICMP.
2. **Traces run to the time budget.** Unreached traces never hit
   `buildResult`'s "stop at target" rule or `sendProbes`' "reached" break. The
   hop list extends to whatever TTL was probed before the run deadline or the
   consecutive-unknown cutoff. The "hop count" is an artefact of the profile's
   timeout, probe interval and unknown-hop limit.
3. **Every probe is a new flow.** `dstPort := seq` and
   `srcPort := 33434 + seq%1000` give every probe a distinct 5-tuple. ECMP
   per-flow hashing may route TTL *n* and TTL *n+1* differently, and random
   high ports are exactly what edge firewalls drop. This is why transit hops go
   quiet partway along the path.
4. **Send failures are hidden.** A send failure rolls back `Sent` and is logged
   at debug level. If every send fails, `buildResult` returns zero hops with
   `target_reached=false` and no `error`.

`ServiceRadar.ProcessRegistry` is a Horde registry joined only by core and
agent-gateway nodes. web-ng sets `join_process_registry: false`, and every
registry read from web-ng has to go through RPC. `AgentCommandBus` already does
this (`list_online_agents/0`, `registry_rpc/2`). `MtrAutomationDispatcher` does
not.

## Goals / Non-Goals

**Goals**
- TCP MTR reaches the targets it should, at the TTL where the target answers,
  and follows one ECMP path.
- An operator can explain any hop-count difference between protocols from the
  UI and the docs.
- One profile can probe a target set with any combination of ICMP, UDP and
  TCP.
- TCP traces carry handshake-level diagnostics at the destination, and the
  reply type is recorded per hop.
- Policy dispatch from web-ng works on a cluster where web-ng is not a registry
  member.
- MTR bulk jobs are visible on Active Scans.

**Non-Goals**
- Passive, flow-derived TCP analytics. See D5 for what "retransmissions" and
  "sequence gaps" mean for an active SYN probe, and why flow-level Retx and
  sequence-gap counting belongs to the flow pipeline.
- Application-layer response time (TLS handshake, HTTP time-to-first-byte).
- Multi-protocol ad-hoc scans or sweep-profile MTR mode
  (`add-sweep-profile-mtr-mode` adopts the protocol set later).
- Retiring the standalone MTR checker.

## Decisions

### D1: Raw SYN probing on Linux with a stable flow (`mtr_tcp_syn`)
Agents advertising `mtr_tcp_syn` (Linux with a raw socket) use the stable-flow
probing described here; the non-Linux connect-observe fallback is D2.
- **Send.** Build the IPv4/IPv6 + TCP SYN in the engine and send it on the raw
  socket the tracer already requires for UDP/TCP (`sendFD`).
  - IPv4: an `IPPROTO_TCP` raw socket with `IP_TTL`. The engine computes the
    TCP checksum over the pseudo-header.
  - IPv6: an `IPPROTO_TCP` raw socket with `IPV6_UNICAST_HOPS` and
    `IPV6_CHECKSUM` at offset 16.
  - The source address comes from a routing lookup: `connect()` a UDP socket
    and read `getsockname`.
- **Flow and probe identity.**
  - One source port per trace. It is reserved by binding (not listening) a TCP
    socket for the tracer's lifetime, so nothing else on the host can take it.
  - One destination port per trace, `tcp_port`, default 443.
  - The probe is identified by the TCP sequence number: `isn_base + seq`.
  - ICMP Time Exceeded / Unreachable quote at least the first 8 transport
    bytes (ports and sequence), so intermediate replies match on quoted
    `(dst, sport, dport, seq)`.
- **Receive.** A second raw `IPPROTO_TCP` socket receives segments. Accept only
  `src == target`, `sport == tcp_port`, `dport == reserved port`, with SYN+ACK
  or RST set, and `ack == isn_base + seq + 1` to identify the probe.
  - An ack that matches no in-flight probe is counted as `ack_mismatch` (D5)
    and never credited to a hop.
  - Because no socket is in SYN_SENT on the reserved port, the kernel answers
    each SYN-ACK with a RST. The server's half-open state is torn down, as with
    `tcptraceroute` and `mtr -T`.
- **Reach.** A SYN-ACK or RST from the target sets `target_reached`, and the
  hop at that TTL takes the target address. Both mean "the target's TCP stack
  answered", which is the question reach answers. An open versus closed port is
  a separate diagnostic (D5).
- **Paris-style.** Only TTL and sequence vary, so every TTL hashes to the same
  ECMP path. `ecmp_addrs` then reflects genuine per-packet load balancing, not
  an artefact of changing ports.
- **UDP.** UDP keeps its classic incrementing destination ports, which are
  needed to elicit Port Unreachable. Moving UDP to a stable flow (identifying
  probes by checksum or IP ID) is noted in Open Questions.

**Alternatives considered**
- *Keep the connect socket open and poll it for completion.* This is portable,
  but the kernel retransmits the SYN on its own schedule. That corrupts per-hop
  sent counts and makes retransmission accounting impossible. Kept only as the
  non-Linux fallback (D2).
- *libpcap / AF_PACKET capture.* This adds a dependency and more privilege than
  the raw socket already needed. A raw `IPPROTO_TCP` receive socket is enough
  on Linux.
- *Default port 80, as `mtr -T` uses.* 443 is the port most edge policies
  allow, and an RST still counts as reached. Operators can set any port per
  profile.

### D2: Non-Linux fallback
- On darwin and other non-Linux builds, the TCP probe is a non-blocking
  connect whose socket is kept open until the probe timeout and polled
  (`EISCONN` or writable means SYN-ACK; `ECONNREFUSED` means RST).
- Every probe targets the configured destination port `tcp_port`; a fresh
  source port per probe is permitted, so this path makes no stable-flow or ECMP
  path guarantee.
- The socket is closed with `SO_LINGER 0` as soon as it resolves or times out.
  That keeps the kernel from retransmitting the SYN inside the probe window.
- This mode fixes reach detection. It cannot fill the D5 counters, so the agent
  does not advertise `mtr_tcp_syn`, and those fields stay null.

### D3: Hop semantics and error surfacing
- `buildResult` keeps its current hop list (it stops at the target), and the
  trace also carries two new values:
  - `last_responding_hop`: the highest TTL with any reply. It is derived at
    ingest from the hops, so old agents get it too.
  - `probed_hops`: the depth actually probed.
- `total_hops` keeps its meaning (rows recorded), so history and hop-depth
  charts stay comparable.
- The UI states "reached in N hops" when reached. Otherwise it states
  "no reply past hop N (M probed)" and collapses trailing all-loss hops into
  one row.
- The ICMP Unreachable type and code are stored on the hop that sent them
  (`unreachable_code`), and the trace reports the kind: `port`, `host`, `net`,
  `admin-prohibited`, and so on.
- If a trace sent zero probes, the engine returns an error carrying the last
  send error, for example "IPv6 link-local target requires a zone". The ingest
  path already persists `error`.

### D4: Multi-protocol profiles
- **Attribute.** `MtrPolicy.baseline_protocols`, of type
  `{:array, :atom}`, constrained to items in `[:icmp, :udp, :tcp]`, with
  `min_length: 1`. It is stored in canonical order (icmp, udp, tcp) with
  duplicates removed.
- **Migration.** Add `baseline_protocols text[] NOT NULL DEFAULT '{icmp}'`, and
  backfill `ARRAY[baseline_protocol]`. The Ash resource keeps
  `baseline_protocol` mirrored to the first protocol for rollback and legacy
  callers. The column is dropped in a follow-up after one release.
- **Port.** `MtrPolicy.tcp_port`: integer 1..65535, default 443.
- **Bulk path** (`MtrBaselineScheduler` -> `dispatch_bulk_mtr`).
  - The payload gains `"protocols"` and `"tcp_port"`. `"protocol"` stays in the
    payload, set to the first protocol, so older agents still get a valid
    single-protocol job.
  - An agent advertising `mtr_protocol_set` runs every protocol for a target
    inside one job, one trace per (target, protocol).
  - For an agent without `mtr_protocol_set`, core dispatches a single-protocol
    job with the first protocol of the set and logs the skip. Splitting the set
    into one job per protocol does not work: an agent runs one bulk job at a
    time and rejects a concurrent one as busy. Capability is checked before the
    command is created (`AgentCommandBus.agent_capability?/2`), so no failed
    command row is left behind.
  - As implemented, the agent expands the job into (target, protocol) units
    that flow through the existing slot, progress and adaptive-concurrency
    accounting, so a target's protocols can run on concurrent workers rather
    than strictly one after another. Progress `total_targets` counts units,
    and progress payloads carry `protocols`.
- **Target rows.** `mtr_bulk_job_targets` gains `protocol text NOT NULL
  DEFAULT 'icmp'`, and the unique index becomes `(command_id, target,
  protocol)`.
- **Progress units.** Progress counters count (target, protocol) units. The
  Active Scans row shows targets x protocols.
- **Single-target path** (dispatcher baseline, device Queue MTR). Core fans
  out one `mtr.run` per protocol. Incident and recovery captures trace only the
  set's first protocol: they feed the cohort consensus, which keeps one outcome
  per agent, so several protocols per agent would overwrite each other. The
  existing single-trace result handling stays unchanged. The agent's concurrent on-demand trace limit rises
  from 2 to 3 so a full icmp/udp/tcp set for one target is admitted at once.
- **Cooldown.** One `mtr_dispatch_windows` row still covers the whole set.
  Cooldown is about how often a target is disturbed, not about which
  protocols are used.
- **Interval guidance.** Measured throughput is in (target, protocol) units,
  so the runtime estimate multiplies the scoped target count by the protocol
  count.
- **Spec correction.** The old spec scenario "UDP/TCP are not auto-executed in
  baseline mode" no longer matches the product: baseline TCP is already
  selectable. The modified requirement replaces it with "the policy's protocol
  set".

### D5: What each TCP diagnostic means for an active SYN probe

cPacket-style metrics come from passively observed flows. For an active SYN
probe, they are defined as follows, and each definition is stated in the UI
tooltip:

| Issue asks for | Field | Definition for SYN probing |
| --- | --- | --- |
| SYNs sent | `tcp_syn_sent` | Destination-phase SYNs sent, including retransmissions |
| SYN-ACKs back | `tcp_synack_received` | SYN-ACKs from the target, matched by ack |
| SYN drop % | `tcp_syn_drop_pct` | Handshakes that never got an answer, as a share of handshakes attempted (first SYN + retries = one attempt) |
| RSTs (server) | `tcp_rst_received` | RST or RST+ACK from the target, matched by ack (port closed or rejected) |
| Retx | `tcp_syn_retransmits`, `tcp_answered_after_retx` | SYNs re-sent after the per-probe timeout, and how many attempts succeeded only on a retry (loss on the first try) |
| Seq gaps | `tcp_ack_mismatch`, `tcp_synack_duplicates` | Replies whose ack matches no probe (sequence rewriting, a SYN proxy or a middlebox), and repeated SYN-ACKs for one probe (the server re-sent because our RST was lost: return-path loss) |
| RTT | per hop `avg_us` etc., and `tcp_handshake_rtt_{min,avg,max}_us` | Network RTT per hop, and SYN->SYN-ACK/RST time at the destination |
| Resp time | `tcp_server_response_us` | `max(0, dest handshake RTT avg - last transit hop RTT avg)`: an estimate of the time spent in the target's stack or host, not on the path |

**Destination phase.** Once the target has been reached (or the path phase
ends), the engine sends `ProbesPerHop` SYNs at the reached TTL, or at MaxHops
if unreached. The per-probe retransmission budget is 1, controlled by
`tcp_syn_retries` with a limit of 0..3. This keeps handshake statistics
independent of how many path cycles happened to hit the destination TTL.

**Per hop.** Every hop gets reply-type counters: `reply_time_exceeded`,
`reply_unreachable`, `reply_synack` and `reply_rst`, plus `unreachable_code`.
These apply to all protocols; SYN-ACK/RST are TCP only. They let the UI show,
for example, "hop 7: 3 sent / 0 replies" versus
"hop 9 (target): 3 SYN / 2 SYN-ACK / 1 RST".

### D6: Web-tier dispatch
- `candidate_agents/1` builds its candidates from
  `AgentCommandBus.list_online_agents/0`. That function reads the registry
  locally on member nodes, or over RPC against core/gateway nodes otherwise,
  and drops dead pids. The session maps already carry `key`, `pid` and
  `metadata`, so `session_to_candidate/1` changes shape only.
- The reader is injectable (the `:session_lister` opt), matching the
  `AgentCommandBus` test seams.
- Two changes to the web-ng Queue MTR path:
  - `MtrRuntime.queue_trace/2` maps dispatcher atoms (`:no_candidates`,
    `:cooldown_active`, `:out_of_scope`, ...) to operator-readable strings.
  - It rescues and logs unexpected exceptions and returns `{:error, message}`,
    so a dispatch fault never crashes the device page.
- An audit task lists every `ProcessRegistry` read reachable from web-ng
  modules and routes any others found through the same RPC-safe helpers.

### D7: Active Scans rows
- A new loader, `NetworksLive.Index.MtrJobs`, reads `AgentCommand` rows with
  `command_type == "mtr.bulk_run"`:
  - running: status in queued/sent/acknowledged/running
  - recent: terminal statuses, newest first, same limit as sweeps
- The rows are normalized into `%ScanRow{kind: :sweep | :mtr, ...}` next to the
  sweep execution rows.
- **Name.** The profile name resolves from `context["mtr_policy_id"]`. Jobs
  without a policy show "Manual".
- **Reached count.** The agent counts completed traces that reached their
  target and reports `reached_targets` on the bulk job result. This avoids
  scanning `mtr_traces` for every recent job on each refresh. The field is
  set only on the job result, so a job that reached none reports `0`, while
  jobs from agents that predate the field show "-".
- **Link.** A row links to `/diagnostics/mtr` filtered by the job's agent,
  where the bulk jobs panel lists that agent's jobs; the diagnostics page has
  no per-job URL.
- **Refresh.** `Infos` routes `{:command_progress | :command_result, ...}` for
  `mtr.bulk_run` into the MTR rows. The 15 s poll remains the backstop.
- **Permissions.** MTR rows and the filter are rendered only when the user
  holds the `networks.sweeps.view` permission. Sweep rows keep their existing
  gate. `AgentCommand` has its own read policy (operator or admin role), so a
  custom role profile can grant the permission without the role. A forbidden
  read hides the MTR rows and the filter exactly as a missing permission does;
  the loaders return `:forbidden` for it, other read errors degrade to empty
  rows, and the read policy is deliberately not widened. The disconnected
  mount loads nothing.

## Risks / Trade-offs

- **Raw TCP needs CAP_NET_RAW.** UDP/TCP probing already requires the raw send
  socket, so the privilege boundary is unchanged. Without it the agent reports
  the existing "requires raw socket" error instead of the fallback.
- **Extra RSTs on the network.** The kernel RSTs every SYN-ACK. That is normal
  for TCP traceroute, and the handshake phase is bounded by
  `ProbesPerHop x (1 + retries)` per trace.
- **History discontinuity.** TCP hop depth changes when fixed agents roll out.
  Mitigation: release note, and `last_responding_hop` and `probed_hops` make
  the change visible instead of looking like a path change.
- **Multi-protocol load.** A three-protocol profile triples probe volume per
  target. Mitigation: interval guidance scales with the protocol count (D4),
  the form shows the multiplier, and bulk concurrency is unchanged.
- **Kernel RST races on the reserved port.** Binding without listening is
  required. A listening or connecting socket would make the kernel complete
  the handshake. Unit tests assert the reservation socket is never
  `listen()`ed.

## Migration Plan

1. Ship #4578 (web-tier dispatch) first. It is independent and user-visible.
2. Ship the engine plus agent (D1-D3, D5 capture). The agent advertises
   `mtr_tcp_syn` and `mtr_protocol_set`. Additive JSON fields are ignored by
   an older core.
3. Ship the core migrations, the resources, the ingestor and SRQL for the new
   columns. They are nullable, so old agents simply leave them null.
4. Ship the multi-protocol policy migration, dispatch and form.
5. Ship Active Scans MTR rows and the docs.
6. Verify on demo: the live baseline TCP profile must show targets reached at
   the ICMP-equivalent depth. See tasks for the artefact queries.

**Rolling upgrade (multi-protocol migration).** Replacing the
`(command_id, target)` unique index on `mtr_bulk_job_targets` with
`(command_id, target, protocol)` means pods still on the previous release fail
bulk MTR dispatches (their `ON CONFLICT (command_id, target)` has no matching
index) until they roll. Rollouts are short in a single deployment, so this is
accepted and documented rather than split into an expand/contract release.

**Rollback.**
- Each step is independently revertible.
- The policy backfill keeps `baseline_protocol` populated until the follow-up
  drop, so rolling back step 4 loses nothing.
- Rolling back step 4 in code alone is not enough: run the multi-protocol
  migration's `down` first. It collapses multi-protocol bulk target rows to one
  per target and restores the `(command_id, target)` unique index the previous
  release upserts against.

## Open Questions

- Should UDP also move to a stable flow (Paris UDP, identifying probes by
  checksum)? Proposed as a follow-up. It changes UDP hop semantics the same way
  D1 changes TCP.
- Should the device page's ad-hoc "Run MTR" modal allow choosing a protocol
  set, or keep a single protocol? Proposed: keep single for ad-hoc, sets for
  profiles.
- Flow-derived Retx / sequence-gap metrics per path (from NetFlow/IPFIX or
  netprobe) would complement D5. Out of scope; to be filed separately if
  wanted.
