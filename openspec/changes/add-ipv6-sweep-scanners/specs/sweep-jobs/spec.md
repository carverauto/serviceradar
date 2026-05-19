## ADDED Requirements
### Requirement: Sweep profiles expose effective IPv6 scanner capabilities
Sweep profile execution SHALL preserve operator-selected scan modes while exposing the effective scanner capabilities available on the assigned agent for IPv4 and IPv6 targets.

#### Scenario: Profile includes IPv6-capable modes
- **GIVEN** a sweep profile enables `icmp` and `tcp`
- **AND** the assigned agent advertises ICMPv6 and IPv6 raw SYN capability
- **WHEN** the sweep config is compiled and executed
- **THEN** IPv6 targets SHALL remain eligible for ICMPv6 and raw SYN scans
- **AND** execution diagnostics SHALL identify the IPv6 scanner paths used

#### Scenario: Agent lacks IPv6 raw SYN capability
- **GIVEN** a sweep profile enables `tcp`
- **AND** the assigned agent does not advertise IPv6 raw SYN capability
- **WHEN** the sweep config is compiled or executed for IPv6 targets
- **THEN** the system SHALL expose a clear diagnostic that raw IPv6 SYN scanning is unavailable for that agent
- **AND** SHALL use TCP connect fallback only when the profile or agent policy permits it
- **AND** SHALL NOT silently mark IPv6 TCP targets as scanned by the raw SYN scanner

### Requirement: Sweep job diagnostics distinguish address families
Sweep job execution diagnostics SHALL distinguish IPv4 and IPv6 scan counts, skipped targets, fallbacks, and scanner errors.

#### Scenario: Mixed-family sweep completes
- **GIVEN** a sweep execution includes both IPv4 and IPv6 targets
- **WHEN** the sweep completes
- **THEN** the execution diagnostics SHALL include counts for IPv4 and IPv6 targets scanned
- **AND** SHALL include counts for ICMP, TCP raw SYN, and TCP connect execution paths
- **AND** SHALL include skipped or fallback counts by address family when applicable
