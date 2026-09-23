## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: TCP SYN Probe Flow
The agent SHALL send all TCP probes of one trace on a single stable flow -- one source port reserved for the trace and one destination port -- varying only TTL and TCP sequence number, and SHALL identify each probe by its TCP sequence number in both quoted ICMP errors and SYN-ACK/RST acknowledgement numbers.

#### Scenario: ECMP-stable TCP path
- **WHEN** a TCP trace probes TTL 1 through N
- **THEN** every probe shares the same source address, source port, destination address and destination port
- **AND** probes differ only in TTL and TCP sequence number

#### Scenario: Reply matched by acknowledgement number
- **WHEN** the target returns a SYN-ACK whose acknowledgement number is one greater than an in-flight probe's sequence number
- **THEN** that probe is credited with the reply at its TTL
- **AND** a reply whose acknowledgement matches no in-flight probe is counted as an acknowledgement mismatch and credited to no hop

#### Scenario: Reserved source port is never listening
- **WHEN** the agent reserves the trace's TCP source port
- **THEN** the reservation socket is bound but never placed in listen or connect state
- **AND** the host kernel answers target SYN-ACKs with RST, tearing down the target's half-open connection

#### Scenario: Platform without raw TCP receive
- **WHEN** the agent runs on a platform that cannot receive raw TCP segments
- **THEN** TCP probes detect reach by observing the non-blocking connect outcome within the probe timeout
- **AND** the agent does not advertise the `mtr_tcp_syn` capability and TCP handshake diagnostics are left empty

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
An MTR profile (policy) SHALL carry a non-empty set of probe protocols drawn from ICMP, UDP and TCP, plus a TCP destination port, and the system SHALL produce one trace per target per protocol in the set for every dispatch of that profile.

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
- **THEN** core dispatches one bulk job per protocol to that agent
- **AND** the resulting traces are indistinguishable from a single multi-protocol job's traces

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
