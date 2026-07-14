## ADDED Requirements

### Requirement: Incomplete variant uses ParseContext and optional expected size
The `SflowError::Incomplete` variant SHALL have the following fields:
- `available: usize` — number of bytes available
- `expected: Option<usize>` — expected number of bytes when known, `None` otherwise
- `context: ParseContext` — the parsing phase where the error occurred

#### Scenario: Incomplete error for a header field
- **WHEN** the parser fails to read the `sub_agent_id` field due to insufficient bytes
- **THEN** the error SHALL be `SflowError::Incomplete { available: <n>, expected: None, context: ParseContext::SubAgentId }`

#### Scenario: Incomplete error for sample data with known expected size
- **WHEN** a sample declares a body length of 64 bytes but only 10 bytes remain
- **THEN** the error SHALL be `SflowError::Incomplete { available: 10, expected: Some(64), context: ParseContext::SampleData }`

#### Scenario: Display format for Incomplete without expected
- **WHEN** `SflowError::Incomplete { available: 3, expected: None, context: ParseContext::DatagramHeaderVersion }` is formatted
- **THEN** the output SHALL be `"Incomplete data: only 3 bytes available (datagram header version)"`

#### Scenario: Display format for Incomplete with expected
- **WHEN** `SflowError::Incomplete { available: 10, expected: Some(64), context: ParseContext::SampleData }` is formatted
- **THEN** the output SHALL be `"Incomplete data: only 10 bytes available, expected 64 (sample data)"`

### Requirement: ParseError variant uses ParseContext and ParseErrorKind
The `SflowError::ParseError` variant SHALL have the following fields:
- `offset: usize` — byte offset from the start of the datagram
- `context: ParseContext` — the parsing phase where the error occurred
- `kind: ParseErrorKind` — the category of parse error

#### Scenario: ParseError for invalid address type
- **WHEN** an unrecognized address type is encountered at offset 4
- **THEN** the error SHALL be `SflowError::ParseError { offset: 4, context: ParseContext::AgentAddress, kind: ParseErrorKind::InvalidAddressType }`

#### Scenario: ParseError wrapping a nom error
- **WHEN** parsing a flow sample fails with a nom `Eof` error
- **THEN** the error SHALL be `SflowError::ParseError { offset: 0, context: ParseContext::FlowSample, kind: ParseErrorKind::NomError(ErrorKind::Eof) }`

#### Scenario: Display format for ParseError
- **WHEN** `SflowError::ParseError { offset: 4, context: ParseContext::AgentAddress, kind: ParseErrorKind::InvalidAddressType }` is formatted
- **THEN** the output SHALL be `"Parse error at offset 4: InvalidAddressType (agent address)"`

### Requirement: SflowError retains all existing trait implementations
`SflowError` SHALL continue to implement `Debug`, `Clone`, `PartialEq`, `Eq`, `Display`, `std::error::Error`, `Serialize`, and `Deserialize`.

#### Scenario: Error trait implementation
- **WHEN** an `SflowError` is used as a `dyn std::error::Error`
- **THEN** it SHALL compile and function correctly

#### Scenario: Serde round-trip
- **WHEN** an `SflowError::ParseError` is serialized to JSON and deserialized back
- **THEN** the result SHALL equal the original value
