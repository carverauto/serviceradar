## ADDED Requirements

### Requirement: MTR Trace Execution
The agent SHALL execute MTR (My Traceroute) path analysis to a configured target, sending probes with incrementing TTL values from 1 to maxHops, collecting ICMP Time Exceeded and Echo Reply responses to build a hop-by-hop view of the network path. Both IPv4 and IPv6 targets SHALL be supported from day one.

#### Scenario: Successful trace to reachable target
- **WHEN** an MTR check is configured with target "10.0.0.1" and max_hops 30
- **THEN** the agent sends probes with TTL 1 through N until the target responds
- **AND** each responding hop is recorded with its IP address and round-trip time
- **AND** the trace terminates when the target is reached or max_hops is exceeded

#### Scenario: Trace with non-responding hops
- **WHEN** intermediate routers do not respond to probes (stealth hops)
- **THEN** those hops are recorded as non-responding with 100% loss
- **AND** the trace continues past non-responding hops up to the consecutive-unknown limit

#### Scenario: Trace to unreachable target
- **WHEN** the target host is unreachable
- **THEN** the trace records all responding intermediate hops
- **AND** the result indicates the target was not reached
- **AND** the final hop status reflects the ICMP Destination Unreachable code

#### Scenario: IPv6 target trace
- **WHEN** the target resolves to an IPv6 address
- **THEN** IPv6 raw sockets and ICMPv6 packets are used
- **AND** hop-by-hop behavior is identical to IPv4 traces

### Requirement: Multi-Protocol Probing
The agent SHALL support ICMP, UDP, and TCP probe protocols for MTR traces, allowing operators to diagnose path behavior under different protocol handling by intermediate routers and firewalls.

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
- **THEN** the agent initiates TCP SYN connections with controlled TTL values
- **AND** target reached is detected via SYN-ACK or RST from the target address

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
The system SHALL support policy-driven baseline MTR collection for managed devices, where baseline protocol defaults to ICMP and execution cadence is bounded to avoid probe storms.

#### Scenario: Baseline policy targets managed devices
- **WHEN** a baseline MTR policy is enabled for managed devices
- **THEN** managed devices are eligible for scheduled MTR checks without manual per-device ad-hoc commands
- **AND** baseline traces are written to `mtr_traces` and `mtr_hops` with `device_id`/`device_uid` linkage

#### Scenario: Baseline defaults to ICMP
- **WHEN** no protocol override is specified by policy
- **THEN** baseline traces run with ICMP protocol
- **AND** UDP/TCP are not auto-executed in baseline mode

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
