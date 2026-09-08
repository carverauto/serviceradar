## ADDED Requirements

### Requirement: Interface Name Dimensions for Flow Queries
The SRQL engine SHALL support `in_if_name`, `out_if_name`, `in_if_description`, `out_if_description`, `in_if_speed`, `out_if_speed`, `in_if_boundary`, and `out_if_boundary` as filter and group-by dimensions for `in:flows` queries. These dimensions SHALL be resolved by LEFT JOIN to the `platform.flow_interface_cache` table keyed by `(sampler_address, if_index)`.

#### Scenario: Filter flows by ingress interface name
- **WHEN** a user executes `in:flows in_if_name:GigabitEthernet0/0`
- **THEN** SRQL returns only flows whose input SNMP index resolves to interface name `GigabitEthernet0/0` via the flow interface cache

#### Scenario: Group flows by egress interface
- **WHEN** a user executes `in:flows stats:"sum(bytes_total) by out_if_name"`
- **THEN** SRQL groups results by the resolved output interface name

### Requirement: Exporter Metadata Dimensions
The SRQL engine SHALL support `exporter_name`, `exporter_site`, `exporter_role`, and `exporter_group` as filter and group-by dimensions for `in:flows` queries. These SHALL be resolved from the flow interface cache via sampler_address lookup.

#### Scenario: Group flows by exporter name
- **WHEN** a user executes `in:flows stats:"sum(bytes_total) by exporter_name"`
- **THEN** SRQL groups results by the resolved exporter device name

### Requirement: EType Dimension
The SRQL engine SHALL support `etype` as a filter and group-by dimension representing the Ethernet type (IPv4=0x0800, IPv6=0x86dd). Display labels SHALL show "IPv4" and "IPv6" instead of raw numeric values.

#### Scenario: Filter by IPv4 flows only
- **WHEN** a user executes `in:flows etype:ipv4`
- **THEN** SRQL returns only flows with etype=0x0800

#### Scenario: Group by etype
- **WHEN** a user executes `in:flows stats:"count(*) by etype"`
- **THEN** results show rows labeled "IPv4" and "IPv6" with respective counts

### Requirement: TCP Flags Dimension
The SRQL engine SHALL support `tcp_flags` as a filter dimension with both numeric bitmask and symbolic names (SYN, ACK, FIN, RST, PSH, URG).

#### Scenario: Filter for SYN-only packets
- **WHEN** a user executes `in:flows tcp_flags:SYN`
- **THEN** SRQL returns flows where the SYN bit is set in the tcp_flags bitmask

### Requirement: Additional Flow Dimensions
The SRQL engine SHALL support the following additional filter and group-by dimensions for `in:flows`:
- `ip_tos` / `dscp` - IP Type of Service / Differentiated Services Code Point
- `next_hop` - Next-hop IP address
- `flow_direction` - Exporter-perspective flow direction (ingress/egress)
- `src_vlan` / `dst_vlan` - Source and destination VLAN IDs
- `sampling_rate` - Flow sampling rate

#### Scenario: Group by DSCP marking
- **WHEN** a user executes `in:flows stats:"sum(bytes_total) by dscp"`
- **THEN** results show traffic volume grouped by DSCP value

#### Scenario: Filter by VLAN
- **WHEN** a user executes `in:flows src_vlan:100`
- **THEN** SRQL returns only flows from VLAN 100

### Requirement: Network Dictionary Group-By
The SRQL engine SHALL support `net:<dictionary_name>:<attribute>` syntax as a group-by dimension that resolves IP addresses to metadata from admin-defined network dictionaries via CIDR containment matching.

#### Scenario: Group by network zone
- **GIVEN** a network dictionary named "zones" with entries mapping CIDRs to zone_name attributes
- **WHEN** a user executes `in:flows stats:"sum(bytes_total) by net:zones:zone_name"`
- **THEN** results show traffic volume grouped by the zone_name attribute from matching dictionary entries

### Requirement: Multi-Resolution Auto-Selection
The SRQL engine SHALL automatically select the optimal continuous aggregate resolution based on the query time range: raw data for <6h, 5min aggregate for 6h-48h, 1h aggregate for 2d-30d, and 1d aggregate for 30d+. The resolution selection SHALL be transparent to the user.

#### Scenario: Short query uses raw data
- **WHEN** a user executes `in:flows time:last_1h stats:"sum(bytes_total) by protocol_group"`
- **THEN** SRQL queries the raw `ocsf_network_activity` hypertable

#### Scenario: Long query uses daily aggregate
- **WHEN** a user executes `in:flows time:last_90d stats:"sum(bytes_total) by protocol_group"`
- **THEN** SRQL queries the 1d continuous aggregate for faster response

### Requirement: Units Parameter
The SRQL engine SHALL support a `units:` parameter for flow queries that controls the aggregation output: `bps` (bits per second), `Bps` (bytes per second), `pps` (packets per second), `pct` (percentage of interface capacity).

#### Scenario: Query returns bits per second
- **WHEN** a user executes `in:flows units:bps stats:"sum(bytes_total) by protocol_group"`
- **THEN** SRQL calculates `sum(bytes_total) * 8 / interval_seconds` and labels the metric as bits/sec

### Requirement: Three-Tier Application Classification
The SRQL engine SHALL classify flows into applications using a three-tier hierarchy: (1) admin override rules (highest priority), (2) IP range database matches, (3) baseline port mapping. The resulting `app` label SHALL use COALESCE semantics.

#### Scenario: IP range match overrides port baseline
- **GIVEN** a flow to destination IP in the Netflix CIDR range on port 443
- **WHEN** SRQL classifies the application
- **THEN** the app label is "Netflix" (from IP range match) rather than "https" (from port baseline)

#### Scenario: Admin rule overrides IP range
- **GIVEN** an admin rule mapping port 8080 on CIDR 10.0.0.0/8 to "internal-api"
- **AND** a flow matching that rule also matches an IP range entry
- **WHEN** SRQL classifies the application
- **THEN** the app label is "internal-api" (admin rule takes precedence)
