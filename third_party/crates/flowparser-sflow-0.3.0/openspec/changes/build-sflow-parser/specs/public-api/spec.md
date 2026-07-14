## ADDED Requirements

### Requirement: SflowParser default construction
The parser SHALL provide a `SflowParser::default()` constructor that creates a parser with no configuration, ready to parse sFlow v5 datagrams.

#### Scenario: Create default parser and parse bytes
- **WHEN** a user creates `SflowParser::default()` and calls `parse_bytes(data)`
- **THEN** it SHALL return a `ParseResult` containing parsed datagrams

### Requirement: SflowParser builder pattern
The parser SHALL provide a `SflowParser::builder()` method returning an `SflowParserBuilder` that supports optional configuration before building.

#### Scenario: Configure max samples limit
- **WHEN** a user creates a parser with `.with_max_samples(100).build()`
- **THEN** the parser SHALL reject datagrams declaring more than 100 samples with a `TooManySamples` error

#### Scenario: Build with defaults
- **WHEN** a user calls `SflowParser::builder().build()`
- **THEN** it SHALL return a parser equivalent to `SflowParser::default()`

### Requirement: Parse bytes method
The parser SHALL provide a `parse_bytes(&self, packet: &[u8]) -> ParseResult` method that parses one or more sFlow datagrams from a byte slice. The method takes `&self` (not `&mut self`) since parsing is stateless.

#### Scenario: Parse valid datagram
- **WHEN** `parse_bytes` receives a valid sFlow v5 datagram
- **THEN** it SHALL return a `ParseResult` with one `SflowDatagram` and no error

#### Scenario: Parse truncated input
- **WHEN** `parse_bytes` receives a byte slice shorter than the minimum datagram header size
- **THEN** it SHALL return a `ParseResult` with an `Incomplete` error

### Requirement: ParseResult type
`ParseResult` SHALL contain a `datagrams: Vec<SflowDatagram>` field and an `error: Option<SflowError>` field, allowing partial results when parsing fails mid-stream.

#### Scenario: Partial parse on error
- **WHEN** input contains 2 datagrams and the second is malformed
- **THEN** `ParseResult` SHALL contain 1 successfully parsed datagram and an error describing the failure

### Requirement: SflowError enum
The parser SHALL define an `SflowError` enum with at least these variants: `Incomplete` (not enough bytes), `UnsupportedVersion` (version != 5), `ParseError` (structural parse failure), and `TooManySamples` (exceeds configured limit).

#### Scenario: Error display messages
- **WHEN** an `SflowError` is formatted with `Display`
- **THEN** it SHALL produce a human-readable message including relevant context (e.g., version number, byte count)

#### Scenario: Error serialization
- **WHEN** an `SflowError` is serialized to JSON
- **THEN** it SHALL produce a valid JSON object with the error variant and fields

### Requirement: Serde serialization for all public types
All public types (`SflowDatagram`, `SflowSample`, all record types, `AddressType`, `SflowError`) SHALL derive `Serialize` and `Deserialize`.

#### Scenario: Round-trip JSON serialization
- **WHEN** a parsed `SflowDatagram` is serialized to JSON and deserialized back
- **THEN** the deserialized value SHALL be equal to the original

#### Scenario: JSON output of parsed datagram
- **WHEN** a user calls `serde_json::to_string(&datagram)`
- **THEN** it SHALL produce valid JSON with human-readable IP addresses and MAC addresses

### Requirement: Debug and Clone derives
All public types SHALL derive `Debug` and `Clone`.

#### Scenario: Debug print parsed datagram
- **WHEN** a user prints a parsed datagram with `{:?}`
- **THEN** it SHALL produce a readable debug representation

### Requirement: PartialEq derive
All public types SHALL derive `PartialEq` to enable test assertions.

#### Scenario: Compare parsed datagrams
- **WHEN** the same bytes are parsed twice
- **THEN** the two resulting `SflowDatagram` values SHALL be equal via `==`
