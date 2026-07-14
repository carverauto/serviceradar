## ADDED Requirements

### Requirement: Parse Counter Sample header
The parser SHALL parse Counter Sample (enterprise=0, format=2) headers containing: sequence_number (u32), source_id (u32, encoding type in upper 8 bits and index in lower 24 bits), and num_records (u32).

#### Scenario: Parse counter sample with multiple records
- **WHEN** the parser receives a Counter Sample with 3 counter records
- **THEN** it SHALL correctly parse the header and return all 3 counter records

### Requirement: Parse Expanded Counter Sample header
The parser SHALL parse Expanded Counter Sample (enterprise=0, format=4) headers containing: sequence_number (u32), source_id_type (u32), source_id_index (u32), and num_records (u32).

#### Scenario: Parse expanded counter sample with separate source ID fields
- **WHEN** the parser receives an Expanded Counter Sample
- **THEN** it SHALL parse source_id_type and source_id_index as separate u32 fields

### Requirement: Dispatch counter records by enterprise and format
The parser SHALL read each counter record's enterprise/format pair and length, then dispatch to the appropriate counter record parser.

#### Scenario: Dispatch known counter record types
- **WHEN** the parser encounters enterprise=0 counter records with format 1 (Generic Interface), 2 (Ethernet Interface), 3 (Token Ring), 5 (VLAN), or 1001 (Processor)
- **THEN** it SHALL dispatch to the corresponding record parser

#### Scenario: Handle unknown counter record types
- **WHEN** the parser encounters an unrecognized counter record enterprise/format pair
- **THEN** it SHALL capture it as an UnknownRecord with the enterprise, format, and raw data bytes

### Requirement: Parse Generic Interface counter record
The parser SHALL parse Generic Interface counter records (enterprise=0, format=1) containing: if_index (u32), if_type (u32), if_speed (u64), if_direction (u32), if_status (u32), if_in_octets (u64), if_in_ucast_pkts (u32), if_in_multicast_pkts (u32), if_in_broadcast_pkts (u32), if_in_discards (u32), if_in_errors (u32), if_in_unknown_protos (u32), if_out_octets (u64), if_out_ucast_pkts (u32), if_out_multicast_pkts (u32), if_out_broadcast_pkts (u32), if_out_discards (u32), if_out_errors (u32), if_promiscuous_mode (u32).

#### Scenario: Parse generic interface counters
- **WHEN** the parser receives a Generic Interface counter record with valid fields
- **THEN** it SHALL parse all 19 counter fields including 64-bit octet and speed counters

### Requirement: Parse Ethernet Interface counter record
The parser SHALL parse Ethernet Interface counter records (enterprise=0, format=2) containing: dot3_stats_alignment_errors (u32), dot3_stats_fcs_errors (u32), dot3_stats_single_collision_frames (u32), dot3_stats_multiple_collision_frames (u32), dot3_stats_sqe_test_errors (u32), dot3_stats_deferred_transmissions (u32), dot3_stats_late_collisions (u32), dot3_stats_excessive_collisions (u32), dot3_stats_internal_mac_transmit_errors (u32), dot3_stats_carrier_sense_errors (u32), dot3_stats_frame_too_longs (u32), dot3_stats_internal_mac_receive_errors (u32), dot3_stats_symbol_errors (u32).

#### Scenario: Parse ethernet interface counters
- **WHEN** the parser receives an Ethernet Interface counter record
- **THEN** it SHALL parse all 13 ethernet-specific error counter fields

### Requirement: Parse Token Ring counter record
The parser SHALL parse Token Ring counter records (enterprise=0, format=3) containing the standard IEEE 802.5 statistics fields.

#### Scenario: Parse token ring counters
- **WHEN** the parser receives a Token Ring counter record
- **THEN** it SHALL parse all token ring statistics fields

### Requirement: Parse VLAN counter record
The parser SHALL parse VLAN counter records (enterprise=0, format=5) containing: vlan_id (u32), octets (u64), ucast_pkts (u32), multicast_pkts (u32), broadcast_pkts (u32), discards (u32).

#### Scenario: Parse VLAN counters
- **WHEN** the parser receives a VLAN counter record with vlan_id=100
- **THEN** it SHALL parse the VLAN ID and all 5 traffic counter fields

### Requirement: Parse Processor counter record
The parser SHALL parse Processor counter records (enterprise=0, format=1001) containing: cpu_5s (u32 percentage), cpu_1m (u32 percentage), cpu_5m (u32 percentage), total_memory (u64), free_memory (u64).

#### Scenario: Parse processor counters
- **WHEN** the parser receives a Processor counter record
- **THEN** it SHALL parse CPU utilization percentages and memory values
