## ADDED Requirements

### Requirement: ParseContext enum covers all parsing phases
The `ParseContext` enum SHALL include one variant for every distinct parsing phase or field where errors can originate. The variants SHALL be:
- `DatagramHeader` — top-level datagram header parsing
- `DatagramHeaderVersion` — version field in the datagram header
- `AgentAddress` — agent address field
- `SubAgentId` — sub-agent identifier field
- `SequenceNumber` — datagram sequence number field
- `Uptime` — agent uptime field
- `NumSamples` — sample count field
- `SampleDataFormat` — sample enterprise/format field
- `SampleLength` — sample length field
- `SampleData` — sample body data
- `FlowSample` — flow sample (format=1) parsing
- `CounterSample` — counter sample (format=2) parsing
- `ExpandedFlowSample` — expanded flow sample (format=3) parsing
- `ExpandedCounterSample` — expanded counter sample (format=4) parsing

#### Scenario: Exhaustive match on ParseContext
- **WHEN** a consumer matches on `ParseContext` with all 14 variants
- **THEN** the match SHALL be exhaustive with no wildcard arm needed

#### Scenario: ParseContext is Copy
- **WHEN** a `ParseContext` value is used
- **THEN** it SHALL be `Copy`, `Clone`, `Debug`, `PartialEq`, `Eq`, `Serialize`, and `Deserialize`

### Requirement: ParseContext Display produces human-readable names
Each `ParseContext` variant SHALL implement `Display` producing a lowercase, human-readable string matching the current string literals used in the codebase.

#### Scenario: Display output matches legacy strings
- **WHEN** `ParseContext::DatagramHeaderVersion` is formatted with `Display`
- **THEN** the output SHALL be `"datagram header version"`

#### Scenario: Display for sample types
- **WHEN** `ParseContext::ExpandedFlowSample` is formatted with `Display`
- **THEN** the output SHALL be `"expanded flow sample"`

### Requirement: ParseErrorKind enum covers all error categories
The `ParseErrorKind` enum SHALL include:
- `InvalidAddressType` — an unrecognized address type value was encountered
- `NomError(nom::error::ErrorKind)` — a nom parser error, wrapping the original error kind

#### Scenario: Domain-specific error
- **WHEN** an invalid address type is encountered during parsing
- **THEN** the error SHALL use `ParseErrorKind::InvalidAddressType`

#### Scenario: Nom parser failure
- **WHEN** a nom parser returns an `Err::Error` or `Err::Failure`
- **THEN** the error SHALL use `ParseErrorKind::NomError` wrapping the `nom::error::ErrorKind` from the error

#### Scenario: Nom incomplete error
- **WHEN** a nom parser returns `Err::Incomplete`
- **THEN** the error SHALL use `ParseErrorKind::NomError(nom::error::ErrorKind::Complete)`

### Requirement: ParseErrorKind derives required traits
`ParseErrorKind` SHALL derive `Debug`, `Clone`, `Copy`, `PartialEq`, and `Eq`. Since `nom::error::ErrorKind` does not implement `Serialize`/`Deserialize`, custom serde implementations SHALL be provided.

#### Scenario: Serialize NomError variant
- **WHEN** `ParseErrorKind::NomError(ErrorKind::Eof)` is serialized
- **THEN** the output SHALL be the string `"Eof"` (the Debug name of the nom variant)

#### Scenario: Deserialize NomError variant
- **WHEN** the string `"Eof"` is deserialized as a `ParseErrorKind`
- **THEN** the result SHALL be `ParseErrorKind::NomError(ErrorKind::Eof)`

#### Scenario: Serialize InvalidAddressType
- **WHEN** `ParseErrorKind::InvalidAddressType` is serialized
- **THEN** the output SHALL be the string `"InvalidAddressType"`
