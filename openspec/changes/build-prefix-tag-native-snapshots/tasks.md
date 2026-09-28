## 1. Proposal and native trie core

- [x] 1.1 Validate this proposal and synchronize overlapping pending requirements.
- [x] 1.2 Implement the packed IPv4/IPv6 Rust trie and canonical prefix parsing.
- [x] 1.3 Preserve VRF variants, duplicate merges, and threat-intel member metadata.
- [x] 1.4 Register the crate and its owner tests in Cargo and Bazel; run focused checks.

## 2. Rustler resource boundary

- [x] 2.1 Add mutable builder and immutable snapshot resources, DirtyCpu batched append, and binary-address lookup.
- [x] 2.2 Catch panics and reject failed/consumed builders; prove containment in the release build with unwinding enabled.
- [x] 2.3 Add the Elixir native engine adapter and wire the NIF into Mix/Bazel/release inputs.
- [x] 2.4 Run cross-engine behavioral parity, metadata, and resource-lifetime tests.

## 3. Bounded snapshot loading

- [x] 3.1 Extend Store with streaming fingerprint-before-build and atomic resource publication.
- [x] 3.2 Stream provider rows pinned to their snapshot ID and retain unchanged-token skips.
- [x] 3.3 Stream threat-intel rows with complete prefix groups across batch boundaries.
- [x] 3.4 Stream snapshot-backed sources, including manual, and retain the old snapshot on failure.
- [ ] 3.5 Test unchanged snapshots, rollback, empty snapshots, and concurrent publication.

## 4. Node placement and preview

- [x] 4.1 Disable external trie construction on web across boot, retries, invalidation, and direct reload.
- [x] 4.2 Preserve nodeup's external-source skip and add a behavioral regression.
- [x] 4.3 Route authorized settings previews to core and make unavailability explicit.
- [x] 4.4 Verify EventWriter enrichment and stored-row readers preserve existing behavior for both telemetry backends.

## 5. Default, scale, and delivery

- [x] 5.1 Enable the native engine by default with explicit Elixir test overrides.
- [x] 5.2 Measure a synthetic provider-scale build and concurrent swaps; verify bounded BEAM memory and a resident resource handle.
- [ ] 5.3 Run formatting, lint, focused integration checks, and the full `make test` gate.
- [ ] 5.4 Submit committed work through no-mistakes for review, push, PR creation, and CI; do not push directly.

## Progress evidence

The native builder, immutable resources, streaming CNPG readers, web-node guards,
and core preview adapter are implemented. NativeEngine is the default. All data
used by new tests is synthetic.

Completed checks:

- Cargo formatting, seven Rust owner tests, and Clippy with warnings denied.
- Optimized remote Bazel Rust owner tests.
- Native ExUnit parity, panic containment, consumed-builder, fingerprint skip,
  old-resource lifetime, and 262,144-prefix bounded-BEAM-heap tests passed in the
  core unit shard, including concurrent publication. The initial preview alias
  error is fixed and the complete shard passes.
- The synthetic 262,144-prefix native build took 1,438 ms on RBE; sampled
  peak builder BEAM memory was 2,921,800 bytes. The snapshot is a resource.
- The focused EventWriter unit shard passed with NativeEngine as default.
- Test-registration contract: 56 tests passed.
- Full `make test`: 363 targets passed; two Swift platform checks skipped.
  Formatting and strict Credo are included and passed.
- Strict OpenSpec validation for this change and the overlapping pending change.

Database cursor-boundary, rollback, and DB-backed UI scenarios await the
BuildBuddy integration/PR checks. A local scratch attempt was stopped during a
cold rebuild of unrelated NIF dependencies before any SQL tests ran; the empty
scratch database and temporary credentials were removed. No deployment, push,
or PR has been made.

The ripwire delta reports heuristic findings for generic result adapters,
constructors, field copies, and address parsing across unrelated subsystems;
callback captures and test entry points are also classified as dead code.
The native insertion-order test deliberately enumerates all permutations.
The external-source integration test is longer because it exercises cursor
boundaries and failure retention through the real database interface. These
findings were reviewed; the report is not claimed clean, and unrelated helper
extraction would obscure the resource and SQL contracts.
