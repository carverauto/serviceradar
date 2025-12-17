## ADDED Requirements

### Requirement: CIDR seed expansion produces unique discovery targets
ServiceRadar MUST expand user-provided CIDR seed ranges into a deterministic list of unique target IP addresses for mapper discovery runs.

#### Scenario: Large IPv4 CIDR expansion is capped but not degenerate
- **GIVEN** a mapper discovery seed CIDR with more than 256 IPv4 addresses (e.g. `192.168.0.0/16`)
- **WHEN** ServiceRadar expands the seed CIDR into target IP addresses
- **THEN** ServiceRadar SHALL return multiple unique IP addresses from within the CIDR range (not a single repeated address)
- **AND** ServiceRadar SHALL cap the expanded target list to at most 256 IP addresses (before any subsequent filtering such as network/broadcast exclusion)

#### Scenario: Small IPv4 CIDR expansion returns all usable hosts
- **GIVEN** a mapper discovery seed CIDR with a small IPv4 host range (e.g. `192.168.0.0/30`)
- **WHEN** ServiceRadar expands the seed CIDR into target IP addresses
- **THEN** ServiceRadar SHALL return all usable host IP addresses in the CIDR range
- **AND** the expanded target list SHALL NOT contain duplicate IP addresses

