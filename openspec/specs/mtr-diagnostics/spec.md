# mtr-diagnostics Specification

## Purpose
MTR diagnostics trace the network path from an agent to a target and record per-hop
latency, loss and reply detail. Traces run on demand from a device page, in bulk jobs
over many targets, and on a schedule from MTR policies. ICMP, UDP and TCP probes are
supported, and a policy can trace each target with several protocols. Results reach
storage through JetStream and are read back for the device MTR tab, the diagnostics
pages and the MTR path analytics dashboard.

## Requirements

### Requirement: Bulk MTR Jobs
The system SHALL support submitting a single bulk MTR job that targets at least 2,400 destinations against one connected agent without relying on one independent on-demand `mtr.run` command per destination.

#### Scenario: Operator submits a 2,400-target bulk job
- **WHEN** an operator submits a bulk MTR request with 2,400 valid targets and one connected MTR-capable agent
- **THEN** the system accepts the request as one bulk job
- **AND** the job is associated to the selected agent
- **AND** the control plane persists job-level and target-level state for the submitted targets

### Requirement: Dedicated Bulk Execution Path
The agent SHALL execute bulk MTR jobs through a dedicated queue and worker path that is independent from the interactive ad-hoc `mtr.run` concurrency limit.

#### Scenario: Bulk job does not consume ad-hoc slots
- **WHEN** a bulk MTR job is running on an agent
- **THEN** the agent schedules bulk targets through the bulk executor
- **AND** the existing interactive `mtr.run` safety cap remains available for ad-hoc operator traces

### Requirement: Bounded High-Throughput Bulk Scheduling
The agent SHALL drain accepted bulk MTR targets through bounded worker concurrency, using reusable execution resources where possible so large jobs complete faster than repeating per-target cold-start traces.

#### Scenario: Bulk executor reuses warm resources
- **WHEN** the agent processes a bulk MTR job with many queued targets
- **THEN** the agent uses long-lived worker and probe resources for the job where practical
- **AND** target execution is paced by a configurable bulk concurrency profile
- **AND** the system does not require a fresh control-stream round trip per target before execution begins

### Requirement: Bulk Job Progress And Terminal States
The system SHALL track bulk MTR job lifecycle and per-target lifecycle through explicit queued, running, completed, failed, canceled, and timed-out terminal semantics.

#### Scenario: Bulk job reaches a terminal state
- **WHEN** the final target in a bulk MTR job reaches a terminal state
- **THEN** the control plane marks the job as completed, failed, canceled, or partially completed according to aggregate outcome rules
- **AND** the job no longer appears as active

#### Scenario: Progress is visible while the job is draining
- **WHEN** a bulk MTR job is in progress
- **THEN** the system reports at least queued, running, completed, failed, and total target counts
- **AND** operators can inspect per-target state without waiting for the full job to finish

### Requirement: Bulk Job Fairness And Safety
The system SHALL provide bulk execution controls that bound local resource use and prevent one large bulk MTR job from starving all other diagnostics activity on the same agent.

#### Scenario: Bulk job concurrency is bounded
- **WHEN** the selected agent is executing a bulk MTR job
- **THEN** the bulk executor enforces configured concurrency and pacing limits
- **AND** excess targets remain queued rather than being rejected solely because they exceed immediate worker capacity

### Requirement: Bulk Job Cancellation And Retry
The system SHALL allow operators to cancel bulk MTR jobs and retry failed or incomplete targets without recreating a brand-new job definition by hand.

#### Scenario: Operator cancels a running bulk job
- **WHEN** an operator cancels a running bulk MTR job
- **THEN** queued targets stop starting
- **AND** in-flight targets are driven to a terminal canceled or interrupted outcome according to executor rules
- **AND** the job becomes terminal once all in-flight targets settle

#### Scenario: Operator retries failed targets
- **WHEN** an operator requests retry for failed or timed-out targets from a prior bulk MTR job
- **THEN** the system creates a new execution attempt scoped to the selected subset
- **AND** the original job history remains available for audit and comparison

### Requirement: Recurring Bulk MTR Scheduling
The system SHALL support recurring bulk MTR jobs with default no-overlap behavior so a scheduled full-inventory cycle does not silently start on top of an unfinished prior run.

#### Scenario: Scheduled run would overlap an active prior run
- **WHEN** a recurring bulk MTR schedule reaches its next fire time while the previous run is still active
- **THEN** the system does not start a second overlapping run by default
- **AND** the skipped or deferred execution is surfaced to the operator

### Requirement: First-Run Calibration And Throughput Baseline
The system SHALL measure execution duration and throughput for bulk MTR jobs and use that baseline to recommend safe recurring intervals.

#### Scenario: First completed run establishes interval guidance
- **WHEN** the first bulk MTR run for an agent/profile completes
- **THEN** the system records completion time, effective throughput, and outcome counts
- **AND** the UI presents a recommended minimum recurring interval derived from the measured run characteristics

### Requirement: MTR Trace Execution
The agent SHALL execute MTR (My Traceroute) path analysis to a configured target, sending probes with incrementing TTL values from 1 to maxHops, collecting ICMP Time Exceeded and Echo Reply responses (and, for TCP, SYN-ACK and RST segments from the target) to build a hop-by-hop view of the network path. Both IPv4 and IPv6 targets SHALL be supported from day one. Each trace SHALL report, alongside the recorded hops, the depth actually probed (`probed_hops`) and the highest TTL that received any reply (`last_responding_hop`), so that an unreached trace's length is never mistaken for the path length.

#### Scenario: Successful trace to reachable target
- **WHEN** an MTR check is configured with target "192.0.2.10" and max_hops 30
- **THEN** the agent sends probes with TTL 1 through N until the target responds
- **AND** each responding hop is recorded with its IP address and round-trip time
- **AND** the trace terminates when the target is reached or max_hops is exceeded
- **AND** `total_hops` and `last_responding_hop` both equal the TTL at which the target answered

#### Scenario: Trace with non-responding hops
- **WHEN** intermediate routers do not respond to probes (stealth hops)
- **THEN** those hops are recorded as non-responding with 100% loss
- **AND** the trace continues past non-responding hops up to the consecutive-unknown limit

#### Scenario: Trace to unreachable target
- **WHEN** the target host is unreachable
- **THEN** the trace records all responding intermediate hops
- **AND** the result indicates the target was not reached
- **AND** the hop that returned ICMP Destination Unreachable records the unreachable type and code
- **AND** `last_responding_hop` identifies the last hop that replied while `probed_hops` records how deep probing went

#### Scenario: No probe could be sent
- **WHEN** every probe send fails (for example an IPv6 link-local target without a zone, or a missing raw socket)
- **THEN** the trace result carries an error describing the last send failure
- **AND** the trace is not reported as a successful zero-hop trace

#### Scenario: IPv6 target trace
- **WHEN** the target resolves to an IPv6 address
- **THEN** IPv6 raw sockets and ICMPv6 packets are used
- **AND** hop-by-hop behavior is identical to IPv4 traces

### Requirement: Multi-Protocol Probing
The agent SHALL support ICMP, UDP, and TCP probe protocols for MTR traces, allowing operators to diagnose path behavior under different protocol handling by intermediate routers and firewalls, and every trace SHALL record the protocol (and for TCP the destination port) it used.

#### Scenario: ICMP probe mode
- **WHEN** protocol is set to "icmp"
- **THEN** the agent sends ICMP Echo Request packets with incrementing TTL
- **AND** probes are identified by ICMP ID and Sequence number

#### Scenario: UDP probe mode
- **WHEN** protocol is set to "udp"
- **THEN** the agent sends UDP packets to incrementing destination ports (base 33434)
- **AND** target reached is detected via ICMP Port Unreachable from the target address

#### Scenario: TCP probe mode
- **WHEN** protocol is set to "tcp"
- **THEN** the agent sends TCP SYN segments with controlled TTL values to the configured TCP destination port (default 443)
- **AND** target reached is detected via SYN-ACK or RST from the target address, observed by the agent
- **AND** the hop at the TTL where the target answered records the target address

#### Scenario: TCP target answers only with TCP
- **WHEN** a TCP trace targets a host that answers SYNs with SYN-ACK or RST and never emits ICMP
- **THEN** the trace is marked `target_reached`
- **AND** no hops beyond the answering TTL are recorded

### Requirement: Per-Hop Statistics
The agent SHALL calculate and report running statistics for each hop, including packet loss percentage, minimum/average/maximum/standard deviation of round-trip time, and jitter metrics.

#### Scenario: Statistics after multiple probe cycles
- **WHEN** 10 probes have been sent to each hop
- **THEN** each hop reports: loss%, sent count, received count, last/avg/min/max RTT in microseconds, standard deviation, and jitter

#### Scenario: Jitter calculation
- **WHEN** consecutive probe responses are received for a hop
- **THEN** jitter is calculated as the absolute difference between consecutive RTTs
- **AND** average jitter, worst jitter, and RFC 1889 interarrival jitter are tracked

#### Scenario: Loss calculation excludes in-flight probes
- **WHEN** probes are still in-flight (awaiting response within timeout)
- **THEN** loss percentage is `0` when `(sent - in_flight) <= 0`; otherwise it is
  `100 * (1 - received / (sent - in_flight))`
- **AND** in-flight probes are not counted as lost

### Requirement: ECMP Path Detection
The agent SHALL detect and record multiple responding IP addresses per hop to identify Equal-Cost Multi-Path (ECMP) routing, where multiple routers may respond at the same TTL distance.

#### Scenario: Multiple paths detected at same hop
- **WHEN** different probes at the same TTL receive responses from different IP addresses
- **THEN** all responding addresses are recorded for that hop
- **AND** statistics are tracked per-address within the hop

### Requirement: MPLS Label Extraction
The agent SHALL parse RFC 4884 ICMP extension objects from Time Exceeded responses to extract MPLS Incoming Label Stack entries, recording label value, experimental bits, bottom-of-stack flag, and TTL for each label in the stack.

#### Scenario: MPLS labels present in ICMP response
- **WHEN** an ICMP Time Exceeded response contains RFC 4884 extension objects with class=1 (MPLS) c-type=1
- **THEN** each label entry (20-bit label, 3-bit exp, 1-bit S, 8-bit TTL) is extracted
- **AND** the MPLS label stack is included in the hop result

#### Scenario: No MPLS extensions present
- **WHEN** an ICMP Time Exceeded response does not contain RFC 4884 extensions
- **THEN** the MPLS labels field is empty/null for that hop
- **AND** all other hop data is unaffected

### Requirement: ASN Enrichment at Collection Time
The agent SHALL enrich each hop IP address with Autonomous System Number (ASN) and organization name by performing a local GeoLite2 MMDB lookup at trace completion, storing the complete enriched dataset so downstream consumers require no additional enrichment.

#### Scenario: ASN enrichment with MMDB available
- **WHEN** a trace completes and GeoLite2-ASN.mmdb is available at the configured path
- **THEN** each hop IP is looked up in the MMDB database
- **AND** the hop result includes `asn` (number) and `asn_org` (organization name) fields

#### Scenario: MMDB unavailable graceful degradation
- **WHEN** the GeoLite2-ASN.mmdb file is not available or unreadable
- **THEN** the agent logs a warning at startup
- **AND** traces complete normally with ASN fields left empty
- **AND** no external API calls are made as fallback

### Requirement: DNS Resolution
The agent SHALL perform asynchronous reverse DNS resolution for hop IP addresses, providing hostnames alongside IP addresses in results without blocking the probe loop.

#### Scenario: Successful reverse DNS lookup
- **WHEN** a hop IP address has a valid PTR record
- **THEN** the hostname is included in the hop result
- **AND** DNS resolution does not delay probe timing

#### Scenario: DNS resolution disabled
- **WHEN** the dns_resolve setting is "false"
- **THEN** no reverse DNS lookups are performed
- **AND** only IP addresses are included in hop results

### Requirement: MTR Check Configuration
The agent SHALL accept MTR check configuration via the standard `AgentCheckConfig` mechanism with check_type "mtr", supporting target, interval, timeout, and MTR-specific settings including ASN database path.

#### Scenario: Minimal configuration
- **WHEN** an MTR check is configured with only target and check_type
- **THEN** the agent uses defaults: max_hops=30, probes_per_hop=10, protocol=icmp, probe_interval_ms=100, packet_size=64, dns_resolve=true, asn_db_path=/usr/share/GeoIP/GeoLite2-ASN.mmdb

#### Scenario: Custom configuration
- **WHEN** MTR settings specify max_hops=15, probes_per_hop=5, protocol=udp
- **THEN** the agent respects all custom settings for the trace execution

### Requirement: On-Demand MTR Execution
The agent SHALL support on-demand MTR trace execution via the ControlStream command interface, enabling operators to trigger ad-hoc path diagnostics without pre-configuring a scheduled check.

#### Scenario: On-demand trace via control stream
- **WHEN** a `mtr.run` command is received via ControlStream with a target address
- **THEN** the agent executes a single MTR trace to the specified target
- **AND** results are enriched with ASN, DNS, and MPLS data
- **AND** results are returned via the control stream response

### Requirement: Privilege Handling
The agent SHALL handle network privilege requirements gracefully, using raw sockets when available (CAP_NET_RAW or root) and falling back to unprivileged ICMP on Linux when raw sockets are unavailable.

#### Scenario: Privileged execution
- **WHEN** the agent process has CAP_NET_RAW or runs as root
- **THEN** raw ICMP sockets are used for full protocol support (ICMP, UDP, TCP)

#### Scenario: Unprivileged fallback on Linux
- **WHEN** the agent lacks raw socket privileges on Linux
- **THEN** SOCK_DGRAM ICMP sockets are used for ICMP-only probing
- **AND** UDP and TCP probe modes report an error indicating insufficient privileges

### Requirement: Result Reporting
The agent SHALL report MTR trace results through the standard gateway push pipeline as structured JSON, including per-hop statistics with MPLS labels, ASN data, hostnames, and execution context (agent ID, gateway ID, timestamps). The result payload SHALL be self-contained — no downstream enrichment required.

#### Scenario: Periodic result push
- **WHEN** a scheduled MTR check completes a probe cycle
- **THEN** the full enriched trace result is marshaled to JSON
- **AND** pushed to the gateway via PushStatus as a GatewayServiceStatus message
- **AND** the result includes all hop data with ASN, MPLS, hostname, target reachability, and timing metadata

### Requirement: TimescaleDB Storage
The core system SHALL store MTR trace results in TimescaleDB hypertables (`mtr_traces` for trace metadata, `mtr_hops` for per-hop time-series data) in the `platform` schema, enabling historical path analysis and time-series queries.

#### Scenario: Trace ingestion into hypertables
- **WHEN** an MTR trace result is received by the core system
- **THEN** a row is inserted into `mtr_traces` with trace metadata (target, protocol, hop count, reachability)
- **AND** one row per hop is inserted into `mtr_hops` with full statistics, MPLS labels (JSONB), ASN, hostname

#### Scenario: Historical query by target
- **WHEN** a user queries MTR history for a specific target over a time range
- **THEN** the system returns trace results ordered by timestamp
- **AND** hop-by-hop data is available for each trace in the range

### Requirement: Apache AGE Path Projection
The core system SHALL project MTR trace paths into the `platform_graph` Apache AGE graph as `MTR_PATH` edges between vertices, correlating hop IPs with existing Device vertices when possible and creating HopNode vertices for unknown hops.

#### Scenario: Path projected into AGE graph
- **WHEN** an MTR trace is ingested
- **THEN** for each consecutive hop pair, a `MTR_PATH` edge is created/updated in `platform_graph`
- **AND** hop IPs matching existing Device vertices reuse those vertices
- **AND** hop IPs not matching any Device get a HopNode vertex

#### Scenario: Stale path pruning
- **WHEN** an `MTR_PATH` edge has not been updated within the configured TTL (default 24 hours)
- **THEN** the edge is removed from the graph during the next pruning cycle

### Requirement: God View MTR Overlay
The web UI SHALL provide an MTR path overlay layer in the God View topology visualization, rendering MTR-discovered paths as animated directional edges with latency and loss visual encoding.

#### Scenario: MTR overlay enabled
- **WHEN** the operator enables the MTR overlay layer in God View controls
- **THEN** MTR_PATH edges from `platform_graph` are rendered as animated directional arcs
- **AND** edge color represents latency (green for low, yellow for medium, red for high)
- **AND** edge thickness represents packet loss percentage

#### Scenario: Hop detail on hover
- **WHEN** the operator hovers over an MTR path edge in God View
- **THEN** a tooltip displays full hop statistics (RTT min/avg/max, loss%, jitter, MPLS labels, ASN)

### Requirement: MTR Results Page
The web UI SHALL provide a dedicated MTR diagnostics page listing recent traces with drill-down to hop-by-hop detail, path comparison, and on-demand trace execution.

#### Scenario: Recent traces list
- **WHEN** the operator navigates to the MTR diagnostics page
- **THEN** a table of recent MTR traces is displayed with target, source agent, hop count, reachability, and timestamp
- **AND** traces are filterable by target, agent, and time range

#### Scenario: Trace detail drill-down
- **WHEN** the operator selects a trace from the list
- **THEN** a hop-by-hop table is displayed with: hop number, IP, hostname, ASN/org, loss%, avg/min/max RTT, jitter, MPLS labels
- **AND** per-hop latency sparklines show recent trend

#### Scenario: Path comparison
- **WHEN** the operator selects two traces to the same target
- **THEN** changed hops are highlighted (IP changes, new hops, missing hops)
- **AND** latency differences per hop are shown

### Requirement: Device Detail MTR Tab
The web UI SHALL include an MTR tab on the device detail page showing all traces involving the device and providing a quick action to run an on-demand trace.

#### Scenario: Device MTR history
- **WHEN** the operator views the MTR tab on a device detail page
- **THEN** all traces where the device IP appears as source, target, or intermediate hop are listed
- **AND** historical path and latency trends are charted over time

#### Scenario: On-demand trace from device page
- **WHEN** the operator clicks "Run MTR" on a device detail page
- **THEN** a modal appears to select source agent and protocol
- **AND** submitting triggers an `mtr.run` command via ControlStream
- **AND** results are displayed inline when the trace completes

### Requirement: Managed Device Baseline Traces
The system SHALL support policy-driven baseline MTR collection for managed devices, where the baseline protocol set defaults to ICMP only and execution cadence is bounded to avoid probe storms.

#### Scenario: Baseline policy targets managed devices
- **WHEN** a baseline MTR policy is enabled for managed devices
- **THEN** managed devices are eligible for scheduled MTR checks without manual per-device ad-hoc commands
- **AND** baseline traces are written to `mtr_traces` and `mtr_hops` with `device_id`/`device_uid` linkage

#### Scenario: Baseline defaults to ICMP
- **WHEN** no protocol set is specified by policy
- **THEN** baseline traces run with ICMP protocol only

#### Scenario: Baseline runs the policy protocol set
- **WHEN** a baseline policy's protocol set includes UDP or TCP
- **THEN** baseline traces run once per target for each protocol in the set
- **AND** the recommended minimum baseline interval accounts for the number of protocols

#### Scenario: Automated selection excludes link-local targets
- **WHEN** automated target selection (baseline dispatch, per-target or bulk, and SRQL-selected bulk) matches a target whose address is link-local (IPv4 `169.254.0.0/16`, IPv6 `fe80::/10`, including the IPv4-mapped form)
- **THEN** that target is dropped before any selector limit is applied, so it does not consume a limit slot
- **AND** the scheduler's dispatch summary reports the excluded count as `skipped_link_local`

### Requirement: State-Change Triggered MTR Capture
The system SHALL support event-driven MTR captures when tracked entities transition to degraded or unavailable states, with per-entity cooldown and deduplication.

#### Scenario: Device transitions to degraded
- **WHEN** a managed device state transitions from healthy to degraded
- **THEN** the system enqueues a bounded on-demand MTR capture from an assigned/nearest agent to the device target
- **AND** duplicate triggers inside the configured cooldown window are suppressed

#### Scenario: Recovery transition capture
- **WHEN** a managed device transitions from degraded/unavailable back to healthy
- **THEN** the system MAY capture a recovery MTR trace for before/after comparison
- **AND** recovery captures obey the same cooldown controls

### Requirement: MTR-Derived Causal Signal Envelope
The system SHALL normalize MTR outcomes into a causal signal envelope suitable for DeepCausality ingestion, preserving routing/path context and join keys into topology.

#### Scenario: MTR anomaly emits causal signal
- **WHEN** an MTR trace indicates hop loss/latency/path-change anomaly beyond configured thresholds
- **THEN** a normalized causal signal is emitted with source provenance, severity, event identity, and topology correlation keys
- **AND** raw MTR context (trace/hop details) remains queryable for drill-down

#### Scenario: Healthy baseline emits stabilizing signal
- **WHEN** baseline MTR traces remain within policy thresholds
- **THEN** the normalized signal stream reflects healthy evidence without generating false root-cause escalation

### Requirement: Topology Overlay and Causal-State Integration
God View SHALL consume MTR-derived causal signals as atmosphere updates layered over canonical topology, without forcing structural coordinate recomputation when topology revision is unchanged.

#### Scenario: Causal class update from MTR signal
- **WHEN** MTR-derived causal signals change node/edge causal class assignments
- **THEN** God View updates causal visual classes (`root_cause`, `affected`, `healthy`, `unknown`)
- **AND** topology coordinates remain stable when graph revision has not changed

#### Scenario: Operator escalation to UDP/TCP
- **WHEN** an operator or policy requests protocol escalation for a target
- **THEN** additional UDP and/or TCP traces are executed and associated to the same incident context
- **AND** resulting causal evidence is merged with ICMP baseline evidence for classification

### Requirement: Agent Vantage Selection Strategy
The system SHALL select source agents for automated MTR by policy, defaulting to a primary assigned vantage per target and bounded optional secondary vantages, instead of running from all agents.

#### Scenario: Baseline uses primary vantage
- **WHEN** baseline automated MTR is scheduled for a managed device
- **THEN** the system selects one primary source agent according to assignment policy (partition/gateway affinity and agent health)
- **AND** baseline collection runs from that primary vantage unless policy explicitly enables additional canaries

#### Scenario: Incident fanout is bounded
- **WHEN** a state-change trigger indicates degraded/unavailable behavior
- **THEN** the system MAY fan out MTR to a bounded cohort of additional agents
- **AND** fanout size is constrained by policy limits to prevent probe storms

### Requirement: Multi-Agent Reachability Consensus
The system SHALL treat differing results across source agents as causal evidence and SHALL classify outcomes using explicit consensus semantics.

#### Scenario: One agent fails while others succeed
- **WHEN** one source agent reports target unreachable and peer agents report target reachable
- **THEN** the system classifies this as a path- or vantage-scoped issue rather than a global target outage
- **AND** causal outputs include per-agent evidence and confidence weighting

#### Scenario: Broad failure across cohort
- **WHEN** all or quorum-defined majority of source agents report unreachable or severe path loss
- **THEN** the system elevates target-level causal severity
- **AND** the affected/root-cause classification reflects cross-vantage consensus

### Requirement: MTR Network Pathing Analytics Dashboard
The web UI SHALL provide a network pathing analytics dashboard that uses `in:mtr_hops stats:` SRQL queries to surface hop-level packet loss and latency aggregates, enabling operators to identify shared-path network problems across a device fleet.

The dashboard SHALL include: a highest-loss router addresses panel, a highest-latency router addresses panel, and an ASN-grouped loss panel for shared-path analysis. Each panel SHALL support a time-window selector (minimum: last 1h, 6h, 24h, 7d). Panels SHALL link hop addresses to filtered hop detail views.

Loss panels SHALL use `stats:loss_ratio(sent, received) by <dimension>` and latency panels SHALL use `stats:wavg(avg_us, received) by <dimension>`. `avg(loss_pct)` and `avg(avg_us)` are NOT acceptable here: averaging a percentage is a mean of ratios where loss is a ratio of sums, and an unweighted latency mean treats a value derived from one returned packet as equal to one derived from a hundred. The two computations disagree whenever the hops in a group sent unequal probe counts, which is the normal case, and an AS-level figure derived from a mean of ratios cannot support the shared-path attribution the scenarios below require. Those aggregates and the dashboard's statistical-correctness requirements are owned by `add-mtr-path-analytics`.

#### Scenario: Loss hotspot panel shows highest-loss routers
- **WHEN** an operator loads the analytics dashboard with time window last_24h
- **THEN** the loss hotspot panel displays router addresses ranked by packet loss descending
- **AND** each row shows the address and its loss percentage computed over summed probe counts

#### Scenario: ASN panel identifies shared-path issues
- **WHEN** multiple devices share a common upstream router or AS
- **THEN** the ASN-grouped panel surfaces the shared ASN with its average loss
- **AND** the panel distinguishes shared-path loss (high AS-level loss over summed probe counts) from device-specific loss (low AS-level loss, high per-device hop loss)

#### Scenario: Time window selector filters panel data
- **WHEN** an operator changes the time window from last_24h to last_7d
- **THEN** all panels reload with aggregates computed over the new window

#### Scenario: Empty data renders informative state
- **WHEN** no MTR hops exist for the selected time window
- **THEN** each panel renders an empty-state message rather than an error or blank space

### Requirement: TCP SYN Probe Flow
For TCP traces on agents advertising the `mtr_tcp_syn` capability, the agent SHALL send all TCP probes of one trace on a single stable flow -- one source port reserved for the trace and one destination port -- varying only TTL and TCP sequence number, and SHALL identify each probe by its TCP sequence number in both quoted ICMP errors and SYN-ACK/RST acknowledgement numbers.

#### Scenario: ECMP-stable TCP path
- **WHEN** a TCP trace on an agent advertising `mtr_tcp_syn` probes TTL 1 through N
- **THEN** every probe shares the same source address, source port, destination address and destination port
- **AND** probes differ only in TTL and TCP sequence number

#### Scenario: Reply matched by acknowledgement number
- **WHEN** a TCP trace on an agent advertising `mtr_tcp_syn` receives a SYN-ACK whose acknowledgement number is one greater than an in-flight probe's sequence number
- **THEN** that probe is credited with the reply at its TTL
- **AND** a reply whose acknowledgement matches no in-flight probe is counted as an acknowledgement mismatch and credited to no hop

#### Scenario: Reserved source port is never listening
- **WHEN** an agent advertising `mtr_tcp_syn` reserves the trace's TCP source port
- **THEN** the reservation socket is bound but never placed in listen or connect state
- **AND** the host kernel answers target SYN-ACKs with RST, tearing down the target's half-open connection

#### Scenario: Platform without raw TCP receive
- **WHEN** a TCP trace runs on an agent that cannot receive raw TCP segments and therefore does not advertise `mtr_tcp_syn`
- **THEN** probes target the configured destination port `tcp_port` while a fresh source port per probe is permitted, so this path makes no stable-flow or ECMP path guarantee
- **AND** reach is detected from the non-blocking connect outcome within the probe timeout, where the connect completing means SYN-ACK and refusal means RST
- **AND** TCP handshake diagnostics are left empty

#### Scenario: IPv6 link-local TCP target
- **WHEN** a TCP trace, on either the raw or the connect-based flow, targets an IPv6 link-local address
- **THEN** the agent rejects the target before opening any socket, with an error stating that a link-local IPv6 target needs an interface zone and is not traceable over TCP
- **AND** ICMP and UDP traces to the same address are unchanged

### Requirement: TCP Handshake Diagnostics
For TCP traces on agents advertising `mtr_tcp_syn`, the agent SHALL run a bounded destination handshake phase and report SYNs sent, SYN-ACKs received, RSTs received, unanswered SYNs, SYN drop percentage, SYN retransmissions, handshakes answered only after retransmission, acknowledgement mismatches, duplicate SYN-ACKs, handshake RTT (min/avg/max), and an estimated server response time; and the agent SHALL report per-hop reply-type counters for every protocol.

#### Scenario: Destination handshake summary
- **WHEN** a TCP trace completes path probing
- **THEN** the agent sends `probes_per_hop` SYNs at the target TTL (or max_hops if unreached) with up to `tcp_syn_retries` retransmissions per SYN
- **AND** the trace reports each handshake counter and the SYN drop percentage as unanswered handshakes over attempted handshakes

#### Scenario: Server response time estimate
- **WHEN** the target and at least one transit hop both answered
- **THEN** the trace reports server response time as the destination handshake RTT average minus the last transit hop's RTT average, floored at zero

#### Scenario: Closed port
- **WHEN** the target answers every SYN with RST
- **THEN** the trace is reached and reports RSTs received equal to handshakes attempted and zero SYN-ACKs

#### Scenario: Per-hop reply types
- **WHEN** any trace records a hop reply
- **THEN** the hop counts replies by kind: Time Exceeded, Destination Unreachable, SYN-ACK and RST

#### Scenario: Agent without handshake capability
- **WHEN** a TCP trace comes from an agent without `mtr_tcp_syn`
- **THEN** the handshake fields are stored as null, not zero
- **AND** the UI labels the handshake panel as unavailable for that agent

#### Scenario: Handshake data is queryable
- **WHEN** an operator queries `in:mtr_traces` or `in:mtr_hops` in SRQL
- **THEN** the handshake and reply-type fields are available for filtering and `stats:` aggregation

### Requirement: Multi-Protocol MTR Profiles
An MTR profile (policy) SHALL carry a non-empty set of probe protocols drawn from ICMP, UDP and TCP, plus a TCP destination port, and the system SHALL produce one trace per target per protocol in the set for every baseline dispatch of that profile, while incident and recovery captures, which feed per-agent consensus, SHALL trace only the first protocol of the set.

#### Scenario: Profile with ICMP and TCP
- **WHEN** an operator saves a profile with protocols ICMP and TCP and TCP port 443
- **THEN** each baseline run records one ICMP trace and one TCP trace per target
- **AND** each trace records its protocol, and the TCP trace records destination port 443

#### Scenario: Empty protocol set rejected
- **WHEN** an operator attempts to save a profile with no protocols selected
- **THEN** the profile is not saved and the form reports that at least one protocol is required

#### Scenario: Existing single-protocol profiles migrate
- **WHEN** the migration runs against profiles that carry a single baseline protocol
- **THEN** each profile's protocol set contains exactly that protocol

#### Scenario: Agent without protocol-set support
- **WHEN** a multi-protocol bulk run targets an agent that does not advertise `mtr_protocol_set`
- **THEN** core dispatches a single-protocol bulk job carrying the first protocol of the set, because such an agent runs one bulk job at a time and rejects a concurrent one
- **AND** core logs that the rest of the set was skipped for that agent

#### Scenario: Incident capture uses one protocol per agent
- **WHEN** a device with an ICMP+TCP profile transitions to degraded and an incident capture is dispatched
- **THEN** each selected agent receives one ICMP trace for the target
- **AND** the cohort consensus compares one outcome per agent

#### Scenario: Per-protocol comparison on the device page
- **WHEN** a device has recent traces for more than one protocol
- **THEN** the device MTR tab shows the latest trace for each protocol side by side

### Requirement: Web-Tier MTR Dispatch
The system SHALL allow MTR dispatch -- including policy-based dispatch from the device page -- from any cluster node, including nodes that are not members of the process registry, and a dispatch failure SHALL be reported to the operator without terminating the page.

#### Scenario: Queue MTR from web-ng with an enabled policy
- **WHEN** an operator clicks Queue MTR on a device page served by a web node that does not host the process registry, and an MTR policy is enabled
- **THEN** candidate agents are resolved through the cluster-aware agent session listing
- **AND** the trace is queued on a connected MTR-capable agent

#### Scenario: Dispatch failure is shown, not crashed
- **WHEN** MTR dispatch fails for any reason, including an unexpected exception
- **THEN** the device page shows an error message describing the failure
- **AND** the LiveView process keeps running with its state intact

### Requirement: MTR fleet analytics separates a shared path fault from a failing endpoint

The MTR analytics dashboard SHALL let an operator determine, for a chosen set of devices, whether loss originates on a shared network path or at the endpoints themselves, and SHALL NOT present a single fleet-wide loss figure as the answer.

To that end it SHALL provide loss broken down by hop position, loss by hop address accompanied by the number of traces traversing that address, and reach rate per target. A hop address carrying high loss across many traces indicates a shared path; low reach rate spread across targets whose upstream hops are clean indicates the endpoints.

Every panel SHALL be scopeable to a device set by target address, since a fleet-wide aggregate cannot answer a question asked about particular devices.

#### Scenario: A shared upstream fault is identifiable
- **GIVEN** many devices whose traces traverse a common hop address that is losing probes
- **WHEN** an operator loads the dashboard scoped to those devices
- **THEN** that hop address appears with high loss and a high trace count
- **AND** the operator can distinguish it from a hop seen in only one or two traces

#### Scenario: Failing endpoints are identifiable
- **GIVEN** several devices that are not being reached while their upstream hops are clean
- **WHEN** an operator loads the dashboard scoped to those devices
- **THEN** reach rate per target identifies those devices
- **AND** no shared hop address carries the loss

#### Scenario: Panels are scopeable to a device set
- **WHEN** an operator narrows the dashboard to a chosen set of target addresses
- **THEN** every panel reflects only those devices

### Requirement: Loss attributable to ICMP deprioritization is not presented as a fault

The MTR analytics dashboard SHALL NOT rank hop addresses by loss without qualification, because routers deprioritize replies to probes addressed to themselves and report loss they are not causing.

Loss SHALL be presented in a form that lets a reader tell a real fault from that artifact: broken down by hop position, so loss beginning at a position and continuing is distinguishable from loss at a single position, and accompanied by trace counts. Panel titles and captions SHALL state what is being measured, so a rate-limiting mid-path router is not read as a network fault.

Determining whether loss at a hop persists to subsequent hops requires comparing hop positions within a trace, which the query language cannot express; the dashboard SHALL NOT imply it settles that question. The per-hop trace detail view remains where a finding is confirmed.

#### Scenario: A mid-path rate-limiting router is not ranked as the top fault
- **GIVEN** a mid-path router reporting loss on probes addressed to itself while traffic through it is unaffected
- **WHEN** an operator loads the dashboard
- **THEN** the presentation does not rank that router as the fleet's worst fault without qualification
- **AND** the operator can see that loss does not continue past it

#### Scenario: The dashboard points at the trace detail view for confirmation
- **WHEN** an operator identifies a candidate hop on the dashboard
- **THEN** the dashboard directs them to the per-hop trace view to confirm whether loss persists downstream

#### Scenario: An unqualified fleet-wide loss figure is not presented as the headline
- **WHEN** an operator loads the dashboard
- **THEN** no panel presents loss aggregated across all hop positions as the fleet's loss rate without stating what it includes

### Requirement: MTR path analytics panels use statistically sound aggregates

The MTR path analytics dashboard SHALL compute packet loss as a ratio of summed probe counts and hop latency as a received-weighted mean, and SHALL NOT present a mean of per-hop percentages or an unweighted mean of per-hop latencies as a group's loss or latency.

Loss panels SHALL use `loss_ratio(sent, received)` and latency panels SHALL use `wavg(avg_us, received)`. A group with no probes sent SHALL render as "no data" rather than as zero loss, because zero loss and no measurement are different operational states.

This requirement exists because the two computations disagree whenever the hops in a group sent unequal probe counts, which is the normal case, and because an AS-level loss figure derived from a mean of ratios cannot support distinguishing shared-path loss from device-specific loss.

#### Scenario: Unequal probe counts do not distort a group's loss
- **GIVEN** an address whose hops sent widely differing probe counts within the window
- **WHEN** an operator loads the loss panel
- **THEN** the address's loss reflects total lost probes over total sent probes
- **AND** a single low-sample hop with total loss does not dominate the figure

#### Scenario: No probes sent renders as no data
- **GIVEN** an address with no probes sent in the selected window
- **WHEN** an operator loads the loss panel
- **THEN** the row renders as "no data"
- **AND** it is not shown as zero percent loss

#### Scenario: ASN panel supports shared-path attribution
- **GIVEN** several devices traversing a common upstream autonomous system
- **WHEN** an operator loads the ASN panel
- **THEN** the shared autonomous system's loss is computed over summed probe counts across those devices
- **AND** that figure can be compared against per-device hop loss to attribute the problem to the shared path or to a device

### Requirement: MTR path analytics provides a loss trend over time

The MTR path analytics dashboard SHALL provide a panel showing loss over time within the selected window, grouped by a time bucket, so an operator can distinguish a sustained path problem from a transient one.

The trend panel SHALL use the `time:<duration>` stats group dimension and SHALL render buckets in ascending time order.

#### Scenario: Trend distinguishes sustained from transient loss
- **GIVEN** an address with elevated loss confined to one hour of a 24-hour window
- **WHEN** an operator loads the trend panel
- **THEN** the elevated loss appears in that hour's bucket only
- **AND** the remaining buckets show the unaffected loss level

#### Scenario: Empty window renders an informative state
- **WHEN** no MTR hops exist in the selected window
- **THEN** the trend panel renders an empty-state message rather than an error or blank space

### Requirement: MTR path analytics ships as a built-in dashboard definition backed by live queries

The product SHALL ship the MTR path analytics dashboard as a public authored dashboard definition available to every installation, without requiring an operator to import a dashboard package.

Only the definition ships: the dashboard record and its panels, each panel holding SRQL text. Every panel SHALL execute its query against live data each time the dashboard is loaded. No panel content is precomputed, captured when the definition is created, or stored alongside it.

Creating the definition SHALL be idempotent and SHALL NOT duplicate it or disturb any other built-in dashboard. The dashboard SHALL NOT introduce a new application route, and SHALL NOT require a dashboard SDK renderer artifact.

#### Scenario: Dashboard is present on a fresh installation
- **WHEN** a fresh installation finishes starting
- **THEN** the MTR path analytics dashboard is listed in the dashboard library
- **AND** an operator can open it without importing anything

#### Scenario: Panels reflect current data on every load
- **GIVEN** the dashboard definition was created earlier
- **WHEN** MTR hops are recorded after that point and an operator loads the dashboard
- **THEN** every panel reflects the newly recorded hops
- **AND** no panel serves a value captured when the definition was created

#### Scenario: Repeated application does not duplicate
- **GIVEN** the dashboard definition already exists
- **WHEN** the definition step runs again
- **THEN** exactly one MTR path analytics dashboard exists
- **AND** other built-in dashboards are unchanged

### Requirement: Operator edits to a built-in dashboard survive restarts

The product SHALL preserve operator modifications to a built-in dashboard definition, and SHALL NOT write a shipped panel query, title, or description back over an edited one when the definition step runs again.

An operator SHALL be able to adopt a built-in dashboard as their own: change a panel's SRQL to scope it to chosen devices, add or duplicate panels, and copy the dashboard. A definition step that restores shipped values over operator edits is prohibited. The divergence such a step creates surfaces only after a restart, long after the edit appeared to succeed, which is what makes it worse than refusing the edit outright.

A dashboard record that exists with no panels at all MAY have its shipped panels created, since that is an incomplete definition rather than an operator choice.

#### Scenario: An edited panel query is not reverted
- **GIVEN** an operator narrowed a built-in dashboard panel's SRQL to a chosen set of devices
- **WHEN** the service restarts and the definition step runs
- **THEN** the panel still carries the operator's query
- **AND** the shipped query is not written back over it

#### Scenario: An added panel is not removed
- **GIVEN** an operator added a panel to a built-in dashboard
- **WHEN** the definition step runs again
- **THEN** the added panel remains

#### Scenario: An incomplete definition is completed
- **GIVEN** a built-in dashboard record exists with no panels because creation was interrupted
- **WHEN** the definition step runs again
- **THEN** its shipped panels are created

### Requirement: Changing a dashboard's SRQL requires dashboard edit authority

The product SHALL permit only an actor holding dashboard edit authority to change the SRQL query a dashboard or system report is built on, and SHALL refuse the change for an actor who can merely view the dashboard.

Edit authority means the `analytics.dashboards.edit` permission or an explicit per-dashboard edit grant. Authorization SHALL be enforced at the data layer so it applies to every path that reaches the record, and SHALL fail closed when no rule matches. A built-in dashboard is public and has no owner, so view access SHALL NOT imply edit access for it.

Every interactive path that edits a panel SHALL supply the acting user as the actor, since a policy that is never given an actor does not run.

#### Scenario: A viewer cannot rewrite a built-in dashboard's query
- **GIVEN** an actor holding dashboard view permission but neither edit permission nor an edit grant
- **WHEN** that actor attempts to change a panel's SRQL on the public built-in MTR dashboard
- **THEN** the change is refused
- **AND** the stored query is unchanged

#### Scenario: An editor can scope the query to chosen devices
- **GIVEN** an actor holding `analytics.dashboards.edit`
- **WHEN** that actor narrows a panel's SRQL to a chosen set of devices
- **THEN** the change is saved
- **AND** subsequent loads run the narrowed query

#### Scenario: A per-dashboard grant is accepted by the data layer
- **GIVEN** an actor without `analytics.dashboards.edit` who holds an edit grant on that dashboard
- **WHEN** that actor changes a panel's SRQL through the data layer
- **THEN** the change is saved

#### Scenario: The interactive path is no more permissive than the data layer
- **GIVEN** any actor and any built-in dashboard
- **WHEN** the interactive panel editor decides whether to permit an edit
- **THEN** it refuses in every case the data layer would refuse

Today the interactive editor is strictly narrower than the data layer: its check is dashboard ownership or the `analytics.dashboards.edit` permission, and it does not consult a per-dashboard edit grant. That direction is safe and is what this requirement constrains. The reverse — an interactive path permitting an edit the data layer would refuse — is prohibited.
