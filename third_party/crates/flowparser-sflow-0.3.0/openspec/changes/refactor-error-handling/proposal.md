## Why

The `SflowError` enum uses `String` for `context` and `kind` fields in the `Incomplete` and `ParseError` variants. These are free-form strings scattered across the codebase (e.g., `"datagram header version".to_string()`, `"flow sample".to_string()`). Replacing them with descriptive enums improves type safety, eliminates heap allocations on error paths, enables exhaustive matching by consumers, and makes the error API self-documenting.

## What Changes

- **BREAKING**: Replace `context: String` in `Incomplete` with a new `ParseContext` enum covering all field/phase identifiers (e.g., `DatagramHeaderVersion`, `SubAgentId`, `SequenceNumber`, `SampleDataFormat`, etc.)
- **BREAKING**: Replace `context: String` in `ParseError` with the same `ParseContext` enum
- **BREAKING**: Replace `kind: String` in `ParseError` with a new `ParseErrorKind` enum (e.g., `InvalidAddressType`, `NomError(ErrorKind)`, `Incomplete`)
- Update all error construction sites in `src/datagram.rs`, `src/samples/mod.rs`, and `src/lib.rs`
- Update `Display` impl to produce equivalent human-readable messages
- Update tests in `src/tests.rs` and `tests/error_handling.rs`

## Capabilities

### New Capabilities
- `error-context-enum`: Introduces `ParseContext` and `ParseErrorKind` enums to replace free-form String fields in `SflowError`

### Modified Capabilities
- `public-api`: The `SflowError` variants `Incomplete` and `ParseError` change field types from `String` to enums (breaking change)

## Impact

- **Public API**: Breaking change to `SflowError` — any downstream code matching on `context` or `kind` fields will need to update
- **Code**: Changes across `src/error.rs` (enum definitions + Display), `src/datagram.rs`, `src/samples/mod.rs`, `src/lib.rs` (construction sites), and test files
- **Dependencies**: None added or removed. `nom::error::ErrorKind` is re-used inside `ParseErrorKind`
- **Performance**: Removes heap allocations (`String::to_string()`) on every error path — enums are `Copy`
