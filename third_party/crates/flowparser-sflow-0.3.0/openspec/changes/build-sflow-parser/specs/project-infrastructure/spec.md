## ADDED Requirements

### Requirement: Library crate structure
The project SHALL be a Rust library crate with `src/lib.rs` as the entry point (not `src/main.rs`). The Cargo.toml SHALL use edition 2024 and dual-license MIT OR Apache-2.0.

#### Scenario: Build as library
- **WHEN** a user runs `cargo build`
- **THEN** it SHALL compile as a library crate with no binary target

### Requirement: Runtime dependencies
The Cargo.toml SHALL declare these runtime dependencies: `nom`, `nom-derive`, `serde` (with derive feature), `byteorder`, and `mac_address`.

#### Scenario: Minimal dependency footprint
- **WHEN** the crate is built
- **THEN** it SHALL compile with only the declared runtime dependencies and their transitive dependencies

### Requirement: Dev dependencies
The Cargo.toml SHALL declare dev dependencies for: `criterion` (benchmarks), `insta` (snapshot tests), `tokio` (async examples), `hex` (test data encoding), `serde_json` (JSON tests), `pcap-parser` (pcap examples), and `etherparse` (packet parsing examples).

#### Scenario: Run tests with dev dependencies
- **WHEN** a user runs `cargo test`
- **THEN** all dev dependencies SHALL be available for test and example compilation

### Requirement: Rustfmt configuration
The project SHALL include a `rustfmt.toml` with `max_width = 96` and `reorder_imports = true`, matching `netflow_parser`.

#### Scenario: Format check passes
- **WHEN** `cargo fmt --check` is run on the project
- **THEN** all source files SHALL pass formatting checks

### Requirement: Cargo deny configuration
The project SHALL include a `deny.toml` configuring license allowlists (MIT, Apache-2.0, Unicode-3.0, Zlib) and security advisory checks.

#### Scenario: License compliance
- **WHEN** `cargo deny check licenses` is run
- **THEN** all dependencies SHALL have allowed licenses

### Requirement: GitHub Actions CI workflow
The project SHALL include `.github/workflows/rust.yml` with jobs for: formatting check (`cargo fmt --check`), linting (`cargo clippy --all`), building (`cargo build --verbose`), testing (`cargo test --verbose`), doc tests (`cargo test --doc`), and benchmarks (`cargo bench --verbose`).

#### Scenario: CI runs on push
- **WHEN** code is pushed to any branch or a PR is opened against main
- **THEN** all CI jobs SHALL execute

### Requirement: Security audit workflow
The project SHALL include `.github/workflows/security-audit.yml` running cargo-audit and cargo-deny on a daily schedule and on pushes to main.

#### Scenario: Daily security scan
- **WHEN** the scheduled trigger fires
- **THEN** cargo-audit and cargo-deny advisory checks SHALL run

### Requirement: Dependabot configuration
The project SHALL include `.github/dependabot.yml` configuring weekly updates for Cargo dependencies and GitHub Actions.

#### Scenario: Dependabot creates PRs
- **WHEN** a dependency has a newer version
- **THEN** Dependabot SHALL create a pull request for the update

### Requirement: Example programs
The project SHALL include example programs demonstrating: single-threaded UDP listener, multi-threaded UDP listener, tokio async UDP listener, and pcap file parsing.

#### Scenario: Run UDP listener example
- **WHEN** a user runs `cargo run --example sflow_udp_listener_single_threaded`
- **THEN** it SHALL compile and listen for sFlow datagrams on a UDP socket

#### Scenario: Run pcap example
- **WHEN** a user runs `cargo run --example sflow_pcap`
- **THEN** it SHALL compile and demonstrate parsing sFlow datagrams from a pcap file

### Requirement: Benchmark suite
The project SHALL include Criterion benchmarks measuring parsing performance for: complete datagrams, flow samples, and counter samples.

#### Scenario: Run benchmarks
- **WHEN** a user runs `cargo bench`
- **THEN** Criterion benchmarks SHALL execute and report timing statistics

### Requirement: Fuzz target
The project SHALL include a cargo-fuzz target that fuzzes the main `parse_bytes` entry point with arbitrary byte input.

#### Scenario: Run fuzzer
- **WHEN** a user runs `cargo fuzz run fuzz_target_1`
- **THEN** the fuzzer SHALL exercise the parser with random inputs without panicking

### Requirement: Integration test suite
The project SHALL include integration tests in the `tests/` directory covering: basic parsing, serialization round-trips, error handling edge cases, and multi-sample datagrams.

#### Scenario: All tests pass
- **WHEN** a user runs `cargo test`
- **THEN** all unit and integration tests SHALL pass
