## Context

`SflowError` uses `String` for `context` and `kind` fields across 14 construction sites in `src/datagram.rs`, `src/samples/mod.rs`, and `src/lib.rs`. Every error path allocates on the heap. The set of possible values is finite and known at compile time, making enums a natural fit.

Current string values for `context` (in `Incomplete` and `ParseError`):
- Datagram header fields: `"datagram header"`, `"datagram header version"`, `"agent address"`, `"sub_agent_id"`, `"sequence_number"`, `"uptime"`, `"num_samples"`
- Sample parsing: `"sample data_format"`, `"sample length"`, `"sample data (need N bytes)"` (dynamic)
- Sample types: `"flow sample"`, `"counter sample"`, `"expanded flow sample"`, `"expanded counter sample"`

Current string values for `kind` (in `ParseError`):
- `"invalid address type"` (hardcoded in datagram.rs)
- nom `ErrorKind` debug names via `nom_error_kind()` helper (e.g., `"Eof"`, `"Switch"`)
- `"incomplete"` (from nom `Err::Incomplete`)

## Goals / Non-Goals

**Goals:**
- Replace `context: String` with a `ParseContext` enum
- Replace `kind: String` with a `ParseErrorKind` enum
- Maintain equivalent `Display` output for human-readable messages
- Keep `Serialize`/`Deserialize` working on all error types
- Eliminate heap allocations on error paths

**Non-Goals:**
- Restructuring the `SflowError` variants themselves (e.g., merging `Incomplete` and `ParseError`)
- Adding new error variants or error recovery mechanisms
- Changing the partial-parse behavior (`ParseResult` returning datagrams + optional error)

## Decisions

### 1. ParseContext enum design

**Choice**: A flat enum with one variant per parsing phase/field. The one dynamic case — `"sample data (need N bytes)"` — is handled by adding an `expected: Option<usize>` field to the `Incomplete` variant rather than putting dynamic data in the context enum.

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ParseContext {
    DatagramHeader,
    DatagramHeaderVersion,
    AgentAddress,
    SubAgentId,
    SequenceNumber,
    Uptime,
    NumSamples,
    SampleDataFormat,
    SampleLength,
    SampleData,
    FlowSample,
    CounterSample,
    ExpandedFlowSample,
    ExpandedCounterSample,
}
```

The enum implements `Display` to produce the same human-readable strings used today (e.g., `ParseContext::SubAgentId` displays as `"sub_agent_id"`).

**Rationale**: A flat enum is simple, `Copy`, and exhaustively matchable. The `expected` field on `Incomplete` is a cleaner place for the byte count than embedding it in the context.

**Alternative considered**: Nested enums (e.g., `ParseContext::Datagram(DatagramField)`, `ParseContext::Sample(SampleField)`). Rejected — adds complexity for no benefit given the small number of variants.

### 2. ParseErrorKind enum design

**Choice**: An enum wrapping the two error categories: domain-specific errors and nom parsing errors.

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseErrorKind {
    InvalidAddressType,
    NomError(nom::error::ErrorKind),
}
```

**Serde handling**: `nom::error::ErrorKind` does not implement `Serialize`/`Deserialize`. We implement custom serde for `ParseErrorKind` that serializes the nom variant as its `Debug` name (e.g., `"Eof"`, `"Switch"`), matching the current string output from `nom_error_kind()`.

**Rationale**: Wrapping `nom::error::ErrorKind` directly preserves all information without creating a parallel enum that duplicates nom's ~40 variants. Custom serde is a small, well-scoped addition.

**Alternative considered**: Creating our own `NomErrorKind` enum mirroring nom's variants. Rejected — maintenance burden, and we'd need to update it whenever nom adds variants.

### 3. Incomplete variant gains `expected` field

**Choice**: Add `expected: Option<usize>` to the `Incomplete` variant.

```rust
Incomplete {
    available: usize,
    expected: Option<usize>,
    context: ParseContext,
},
```

`expected` is `Some(n)` only for the sample-data case where the required byte count is known. All other `Incomplete` sites set it to `None`.

**Rationale**: This replaces the dynamic `format!("sample data (need {sample_length} bytes)")` string without polluting the context enum. The `Display` impl includes the expected count when present.

### 4. nom_error_kind helper removal

**Choice**: Remove the `nom_error_kind()` function from `src/samples/mod.rs`. Replace call sites with direct construction of `ParseErrorKind::NomError(e.code)` / `ParseErrorKind::NomError(ErrorKind::Complete)` as appropriate.

**Rationale**: The helper existed solely to convert nom errors to strings. With `ParseErrorKind` wrapping `nom::error::ErrorKind` directly, no conversion is needed.

### 5. Display output compatibility

**Choice**: The `Display` impl produces messages equivalent to the current output. For example:
- `Incomplete { available: 3, expected: None, context: ParseContext::DatagramHeaderVersion }` → `"Incomplete data: only 3 bytes available (datagram header version)"`
- `Incomplete { available: 10, expected: Some(32), context: ParseContext::SampleData }` → `"Incomplete data: only 10 bytes available, expected 32 (sample data)"`

**Rationale**: Downstream consumers may parse or log these messages. Keeping the format stable reduces breakage surface — the breaking change is in the type system, not in human-readable output.

## Risks / Trade-offs

- **Breaking API change** → Semver minor/major bump required. Document migration in changelog. The set of context values is now fixed — consumers gain exhaustive matching but lose the ability to construct errors with arbitrary context strings.
- **nom version coupling** → `ParseErrorKind::NomError` wraps `nom::error::ErrorKind` directly, coupling to nom's API. → Mitigated: nom is already a direct dependency, and ErrorKind is stable across nom 7.x.
- **Custom serde for ParseErrorKind** → Small maintenance cost for the manual Serialize/Deserialize impl. → Mitigated: the impl is straightforward (serialize Debug name, deserialize from string match).
