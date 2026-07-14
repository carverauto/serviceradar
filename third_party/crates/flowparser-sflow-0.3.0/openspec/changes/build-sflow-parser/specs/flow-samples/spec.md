## ADDED Requirements

### Requirement: Parse Flow Sample header
The parser SHALL parse Flow Sample (enterprise=0, format=1) headers containing: sequence_number (u32), source_id (u32, encoding type in upper 8 bits and index in lower 24 bits), sampling_rate (u32), sample_pool (u32), drops (u32), input interface (u32), output interface (u32), and num_records (u32).

#### Scenario: Parse complete flow sample
- **WHEN** the parser receives a Flow Sample with valid header fields and 2 flow records
- **THEN** it SHALL correctly parse all header fields and return both flow records

#### Scenario: Extract source ID components
- **WHEN** the parser parses a Flow Sample with source_id=0x00000003
- **THEN** the source_id_type SHALL be 0 and source_id_index SHALL be 3

### Requirement: Parse Expanded Flow Sample header
The parser SHALL parse Expanded Flow Sample (enterprise=0, format=3) headers containing: sequence_number (u32), source_id_type (u32), source_id_index (u32), sampling_rate (u32), sample_pool (u32), drops (u32), input_format (u32), input_value (u32), output_format (u32), output_value (u32), and num_records (u32).

#### Scenario: Parse expanded flow sample with separate source ID fields
- **WHEN** the parser receives an Expanded Flow Sample
- **THEN** it SHALL parse source_id_type and source_id_index as separate u32 fields (not packed into a single u32)

### Requirement: Dispatch flow records by enterprise and format
The parser SHALL read each flow record's enterprise/format pair and length, then dispatch to the appropriate flow record parser.

#### Scenario: Dispatch known flow record types
- **WHEN** the parser encounters enterprise=0 flow records with format 1 (Raw Packet Header), 2 (Sampled Ethernet), 3 (Sampled IPv4), 4 (Sampled IPv6), 1001 (Extended Switch), 1002 (Extended Router), 1003 (Extended Gateway), 1004 (Extended User), or 1005 (Extended URL)
- **THEN** it SHALL dispatch to the corresponding record parser

#### Scenario: Handle unknown flow record types
- **WHEN** the parser encounters an unrecognized flow record enterprise/format pair
- **THEN** it SHALL capture it as an UnknownRecord with the enterprise, format, and raw data bytes

### Requirement: Parse Raw Packet Header record
The parser SHALL parse Raw Packet Header records (enterprise=0, format=1) containing: header_protocol (u32), frame_length (u32), stripped (u32), header_length (u32), and header bytes (variable length, up to header_length bytes).

#### Scenario: Parse ethernet raw packet header
- **WHEN** the parser receives a Raw Packet Header with header_protocol=1 (Ethernet)
- **THEN** it SHALL parse the header fields and capture the raw header bytes

### Requirement: Parse Sampled Ethernet record
The parser SHALL parse Sampled Ethernet records (enterprise=0, format=2) containing: src_mac (6 bytes), dst_mac (6 bytes), eth_type (u32).

#### Scenario: Parse sampled ethernet with MAC addresses
- **WHEN** the parser receives a Sampled Ethernet record
- **THEN** it SHALL parse source and destination MAC addresses and the ethernet type

### Requirement: Parse Sampled IPv4 record
The parser SHALL parse Sampled IPv4 records (enterprise=0, format=3) containing: length (u32), protocol (u32), src_ip (IPv4), dst_ip (IPv4), src_port (u32), dst_port (u32), tcp_flags (u32), tos (u32).

#### Scenario: Parse sampled IPv4 with addresses and ports
- **WHEN** the parser receives a Sampled IPv4 record
- **THEN** it SHALL parse source/destination IPs as Ipv4Addr and all port/flag fields

### Requirement: Parse Sampled IPv6 record
The parser SHALL parse Sampled IPv6 records (enterprise=0, format=4) containing: length (u32), protocol (u32), src_ip (IPv6), dst_ip (IPv6), src_port (u32), dst_port (u32), tcp_flags (u32), priority (u32).

#### Scenario: Parse sampled IPv6 with addresses
- **WHEN** the parser receives a Sampled IPv6 record
- **THEN** it SHALL parse source/destination IPs as Ipv6Addr and all port/flag fields

### Requirement: Parse Extended Switch record
The parser SHALL parse Extended Switch records (enterprise=0, format=1001) containing: src_vlan (u32), src_priority (u32), dst_vlan (u32), dst_priority (u32).

#### Scenario: Parse extended switch data
- **WHEN** the parser receives an Extended Switch record
- **THEN** it SHALL parse all four VLAN/priority fields

### Requirement: Parse Extended Router record
The parser SHALL parse Extended Router records (enterprise=0, format=1002) containing: next_hop address type (u32), next_hop address (IPv4 or IPv6), src_mask_len (u32), dst_mask_len (u32).

#### Scenario: Parse extended router with IPv4 next hop
- **WHEN** the parser receives an Extended Router record with next_hop address type=1
- **THEN** it SHALL parse the next hop as an IPv4 address

### Requirement: Parse Extended Gateway record
The parser SHALL parse Extended Gateway records (enterprise=0, format=1003) containing: next_hop address, AS number (u32), src_AS (u32), src_peer_AS (u32), AS path count, AS path segments (type + values), communities count, and community values.

#### Scenario: Parse extended gateway with AS path
- **WHEN** the parser receives an Extended Gateway record with 2 AS path segments
- **THEN** it SHALL parse the next hop, AS numbers, and all AS path segments with their types and values

### Requirement: Parse Extended User record
The parser SHALL parse Extended User records (enterprise=0, format=1004) containing: src_charset (u32), src_user_length (u32), src_user (string), dst_charset (u32), dst_user_length (u32), dst_user (string).

#### Scenario: Parse extended user with usernames
- **WHEN** the parser receives an Extended User record with source and destination usernames
- **THEN** it SHALL parse both usernames as UTF-8 strings

### Requirement: Parse Extended URL record
The parser SHALL parse Extended URL records (enterprise=0, format=1005) containing: direction (u32), url_length (u32), url (string), host_length (u32), host (string).

#### Scenario: Parse extended URL
- **WHEN** the parser receives an Extended URL record
- **THEN** it SHALL parse the direction, URL string, and host string
