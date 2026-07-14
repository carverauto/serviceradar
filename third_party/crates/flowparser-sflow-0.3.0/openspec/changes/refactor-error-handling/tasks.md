## 1. Define new enums in src/error.rs

- [x] 1.1 Add `ParseContext` enum with all 14 variants, deriving `Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize`
- [x] 1.2 Implement `Display` for `ParseContext` producing legacy-compatible lowercase strings (e.g., `DatagramHeaderVersion` → `"datagram header version"`)
- [x] 1.3 Add `ParseErrorKind` enum with `InvalidAddressType` and `NomError(nom::error::ErrorKind)` variants, deriving `Debug, Clone, Copy, PartialEq, Eq`
- [x] 1.4 Implement `Display` for `ParseErrorKind` (e.g., `InvalidAddressType` → `"InvalidAddressType"`, `NomError(kind)` → `"{kind:?}"`)
- [x] 1.5 Implement custom `Serialize` and `Deserialize` for `ParseErrorKind` (serialize as Debug name string, deserialize by matching string back to variant)

## 2. Update SflowError variants

- [x] 2.1 Change `Incomplete` variant: replace `context: String` with `context: ParseContext`, add `expected: Option<usize>` field
- [x] 2.2 Change `ParseError` variant: replace `context: String` with `context: ParseContext`, replace `kind: String` with `kind: ParseErrorKind`
- [x] 2.3 Update `Display` impl for `SflowError`: handle `expected` field in `Incomplete` format, use `ParseErrorKind` display in `ParseError` format
- [x] 2.4 Export `ParseContext` and `ParseErrorKind` from `src/lib.rs`

## 3. Update error construction sites

- [x] 3.1 Update `src/lib.rs`: change `context: "datagram header".to_string()` to `context: ParseContext::DatagramHeader` with `expected: None`
- [x] 3.2 Update `src/datagram.rs`: replace all 6 error construction sites with `ParseContext` variants and `ParseErrorKind` values (DatagramHeaderVersion, AgentAddress, SubAgentId, SequenceNumber, Uptime, NumSamples)
- [x] 3.3 Update `src/samples/mod.rs`: replace all 7 error construction sites with `ParseContext` variants (SampleDataFormat, SampleLength, SampleData with `expected: Some(n)`, FlowSample, CounterSample, ExpandedFlowSample, ExpandedCounterSample)
- [x] 3.4 Remove `nom_error_kind()` helper function from `src/samples/mod.rs`, replace with direct `ParseErrorKind::NomError` construction

## 4. Update tests

- [x] 4.1 Update `src/tests.rs`: change `ParseError` construction in display test to use `ParseContext` and `ParseErrorKind`
- [x] 4.2 Update `tests/error_handling.rs`: change `Incomplete` construction in `test_error_display_messages` to use `ParseContext` with `expected: None`
- [x] 4.3 Update `tests/serialization.rs` if it constructs or matches on `SflowError` fields

## 5. Verify

- [x] 5.1 Run `cargo build` — confirm no compilation errors
- [x] 5.2 Run `cargo test` — confirm all existing tests pass
- [x] 5.3 Run `cargo clippy` — confirm no new warnings
