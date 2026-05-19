## ADDED Requirements
### Requirement: Native IPv6 ICMP sweep support
The agent sweeper SHALL support ICMPv6 echo checks for IPv6 targets using IPv6-aware packet construction, response parsing, and timeout handling.

#### Scenario: IPv6 ICMP target receives echo reply
- **GIVEN** a sweep target whose host is an IPv6 address
- **AND** the target mode is `icmp`
- **WHEN** the agent executes the sweep with ICMPv6 capability available
- **THEN** the agent SHALL send an ICMPv6 Echo Request
- **AND** classify a matching ICMPv6 Echo Reply as available
- **AND** record result metadata indicating protocol `icmp` and address family `ipv6`

#### Scenario: ICMPv6 capability is unavailable
- **GIVEN** a sweep target whose host is an IPv6 address
- **AND** the target mode is `icmp`
- **AND** the agent lacks the runtime capability required for ICMPv6 probing
- **WHEN** the sweep executes
- **THEN** the agent SHALL skip the ICMPv6 target with a structured execution diagnostic
- **AND** SHALL NOT route the target to the IPv4 ICMP scanner
- **AND** SHALL NOT emit per-target "invalid IPv4 address" warnings

### Requirement: Native IPv6 raw SYN sweep support
The agent sweeper SHALL support raw TCP SYN port checks for IPv6 targets using IPv6 packet construction, TCP checksums over the IPv6 pseudo-header, and IPv6 response decoding.

#### Scenario: IPv6 TCP target receives SYN-ACK
- **GIVEN** a sweep target whose host is an IPv6 address
- **AND** the target mode is `tcp`
- **AND** the target port is open
- **WHEN** the agent executes the sweep with IPv6 raw SYN capability available
- **THEN** the agent SHALL send an IPv6 TCP SYN probe
- **AND** classify a matching SYN-ACK response as an open port
- **AND** record result metadata indicating protocol `tcp` and address family `ipv6`

#### Scenario: IPv6 TCP target receives RST
- **GIVEN** a sweep target whose host is an IPv6 address
- **AND** the target mode is `tcp`
- **AND** the target port is closed
- **WHEN** the agent receives a matching RST response
- **THEN** the agent SHALL classify the port as closed/reachable according to the existing sweep result contract
- **AND** SHALL NOT treat the target as an IPv4 parse failure

### Requirement: Sweep scanner routing is IP-family aware
The agent sweeper SHALL route targets by parsed IP family and requested sweep mode so IPv4 and IPv6 targets can coexist in a single execution.

#### Scenario: Mixed IPv4 and IPv6 sweep group
- **GIVEN** a sweep group contains IPv4 and IPv6 targets
- **AND** the sweep profile includes `icmp`, `tcp`, and `tcp_connect`
- **WHEN** the agent executes the sweep
- **THEN** IPv4 ICMP targets SHALL use the IPv4 ICMP scanner
- **AND** IPv4 TCP targets SHALL use the IPv4 raw SYN scanner
- **AND** IPv6 ICMP targets SHALL use the ICMPv6 scanner
- **AND** IPv6 TCP targets SHALL use the IPv6 raw SYN scanner when available
- **AND** TCP connect targets SHALL use the TCP connect scanner with valid IPv4 or IPv6 socket addresses

#### Scenario: Unsupported scanner mode emits one diagnostic
- **GIVEN** an agent cannot execute one requested scanner path for an address family
- **WHEN** a sweep contains multiple targets requiring that unavailable path
- **THEN** the agent SHALL emit a bounded structured diagnostic for the unavailable scanner path
- **AND** SHALL NOT spam one warning per host

### Requirement: IPv6 sweep execution remains bounded
The sweeper SHALL avoid accidental broad IPv6 target expansion and SHALL preserve streaming/batched execution semantics for large target sets.

#### Scenario: Broad IPv6 CIDR is configured
- **GIVEN** a sweep configuration includes an IPv6 CIDR whose expanded host count exceeds configured target limits
- **WHEN** target generation runs
- **THEN** the sweeper SHALL reject or bound the generated target stream according to configured limits
- **AND** SHALL emit an operator-visible diagnostic explaining that broad IPv6 enumeration was blocked or capped
- **AND** SHALL NOT allocate a full host list for the CIDR
