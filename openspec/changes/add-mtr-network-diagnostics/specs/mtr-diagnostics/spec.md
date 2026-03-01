## ADDED Requirements

### Requirement: MTR Trace Execution
The agent SHALL execute MTR (My Traceroute) path analysis to a configured target, sending probes with incrementing TTL values from 1 to maxHops, collecting ICMP Time Exceeded and Echo Reply responses to build a hop-by-hop view of the network path.

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
- **THEN** each hop reports: loss%, sent count, received count, last/avg/min/max RTT in milliseconds, standard deviation, and jitter

#### Scenario: Jitter calculation
- **WHEN** consecutive probe responses are received for a hop
- **THEN** jitter is calculated as the absolute difference between consecutive RTTs
- **AND** average jitter and worst jitter are tracked across all probes

#### Scenario: Loss calculation excludes in-flight probes
- **WHEN** probes are still in-flight (awaiting response within timeout)
- **THEN** loss percentage is calculated as `100 * (1 - received / (sent - in_flight))`
- **AND** in-flight probes are not counted as lost

### Requirement: ECMP Path Detection
The agent SHALL detect and record multiple responding IP addresses per hop to identify Equal-Cost Multi-Path (ECMP) routing, where multiple routers may respond at the same TTL distance.

#### Scenario: Multiple paths detected at same hop
- **WHEN** different probes at the same TTL receive responses from different IP addresses
- **THEN** all responding addresses are recorded for that hop
- **AND** statistics are tracked per-address within the hop

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
The agent SHALL accept MTR check configuration via the standard `AgentCheckConfig` mechanism with check_type "mtr", supporting target, interval, timeout, and MTR-specific settings.

#### Scenario: Minimal configuration
- **WHEN** an MTR check is configured with only target and check_type
- **THEN** the agent uses defaults: max_hops=30, probes_per_hop=10, protocol=icmp, probe_interval_ms=100, packet_size=64, dns_resolve=true

#### Scenario: Custom configuration
- **WHEN** MTR settings specify max_hops=15, probes_per_hop=5, protocol=udp
- **THEN** the agent respects all custom settings for the trace execution

### Requirement: On-Demand MTR Execution
The agent SHALL support on-demand MTR trace execution via the ControlStream command interface, enabling operators to trigger ad-hoc path diagnostics without pre-configuring a scheduled check.

#### Scenario: On-demand trace via control stream
- **WHEN** a `mtr.run` command is received via ControlStream with a target address
- **THEN** the agent executes a single MTR trace to the specified target
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

### Requirement: IPv4 and IPv6 Support
The agent SHALL support both IPv4 and IPv6 targets for MTR traces, automatically detecting the address family from the target address or DNS resolution result.

#### Scenario: IPv4 target
- **WHEN** the target resolves to an IPv4 address
- **THEN** IPv4 raw sockets and ICMPv4 packets are used

#### Scenario: IPv6 target
- **WHEN** the target resolves to an IPv6 address
- **THEN** IPv6 raw sockets and ICMPv6 packets are used

### Requirement: Result Reporting
The agent SHALL report MTR trace results through the standard gateway push pipeline as structured JSON, including per-hop statistics, path metadata, and execution context (agent ID, gateway ID, timestamps).

#### Scenario: Periodic result push
- **WHEN** a scheduled MTR check completes a probe cycle
- **THEN** the full trace result is marshaled to JSON
- **AND** pushed to the gateway via PushStatus as a GatewayServiceStatus message
- **AND** the result includes all hop data, target reachability, and timing metadata
