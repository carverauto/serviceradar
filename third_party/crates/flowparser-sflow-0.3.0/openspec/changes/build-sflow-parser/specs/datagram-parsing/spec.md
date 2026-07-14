## ADDED Requirements

### Requirement: Parse sFlow v5 datagram header
The parser SHALL parse sFlow v5 datagram headers containing: version (u32), agent address type (u32), agent address (IPv4 or IPv6), sub-agent ID (u32), sequence number (u32), uptime in milliseconds (u32), and number of samples (u32). All fields are big-endian.

#### Scenario: Parse datagram with IPv4 agent address
- **WHEN** the parser receives bytes with version=5 and agent_address_type=1
- **THEN** it SHALL parse the agent address as a 4-byte IPv4 address and correctly parse all remaining header fields

#### Scenario: Parse datagram with IPv6 agent address
- **WHEN** the parser receives bytes with version=5 and agent_address_type=2
- **THEN** it SHALL parse the agent address as a 16-byte IPv6 address and correctly parse all remaining header fields

#### Scenario: Reject unsupported version
- **WHEN** the parser receives bytes with a version other than 5
- **THEN** it SHALL return an `UnsupportedVersion` error containing the version number

### Requirement: Dispatch samples by enterprise and format
The parser SHALL read each sample's enterprise/format pair from the data_format field (enterprise in upper 20 bits, format in lower 12 bits) and the sample length, then dispatch to the appropriate sample parser.

#### Scenario: Dispatch standard sample types
- **WHEN** the parser encounters enterprise=0 with format 1 (Flow Sample), 2 (Counter Sample), 3 (Expanded Flow Sample), or 4 (Expanded Counter Sample)
- **THEN** it SHALL dispatch to the corresponding sample parser

#### Scenario: Handle unknown sample types
- **WHEN** the parser encounters an unrecognized enterprise/format pair
- **THEN** it SHALL skip the sample using the declared length and continue parsing remaining samples without error

### Requirement: Parse multiple samples per datagram
The parser SHALL parse all samples declared in the header's num_samples field, producing a vector of parsed samples.

#### Scenario: Datagram with multiple samples
- **WHEN** a datagram declares num_samples=3 and contains 3 valid samples
- **THEN** the parser SHALL return all 3 parsed samples in order

#### Scenario: Datagram with zero samples
- **WHEN** a datagram declares num_samples=0
- **THEN** the parser SHALL return an empty samples vector with no error

### Requirement: Address type enum
The parser SHALL represent agent addresses using an `AddressType` enum with variants `IPv4(Ipv4Addr)` and `IPv6(Ipv6Addr)`, using standard library types.

#### Scenario: Serialize IPv4 agent address
- **WHEN** a parsed datagram with an IPv4 agent address is serialized to JSON
- **THEN** the address SHALL appear as a human-readable dotted-quad string

#### Scenario: Serialize IPv6 agent address
- **WHEN** a parsed datagram with an IPv6 agent address is serialized to JSON
- **THEN** the address SHALL appear as a human-readable colon-separated string
