## ADDED Requirements
### Requirement: Configurable Perl Strategy for Rust OpenSSL Builds
The Bazel Rust toolchain integration SHALL provide an explicit strategy for satisfying OpenSSL's Perl requirement during `openssl-src` build steps.

The strategy SHALL support:
- host Perl mode
- hermetic Perl fallback mode

#### Scenario: Host Perl mode selected
- **GIVEN** a supported build environment with Perl available on `PATH`
- **WHEN** a Rust target requiring vendored OpenSSL is built
- **THEN** the build uses host Perl
- **AND** hermetic Perl source bootstrap is not required for that build.

#### Scenario: Hermetic fallback selected
- **GIVEN** an environment that requires hermetic toolchains
- **WHEN** a Rust target requiring vendored OpenSSL is built with fallback enabled
- **THEN** the build uses hermetic Perl
- **AND** the build completes without requiring host Perl.

### Requirement: Default Path Optimizes Build Latency
The default Perl strategy for supported developer and CI environments SHALL minimize cold-build overhead while maintaining successful Rust/OpenSSL builds.

#### Scenario: Cold build avoids unnecessary Perl bootstrap
- **GIVEN** a clean or mostly cold Bazel cache
- **WHEN** a representative Rust target that depends on `openssl-src` is built using the default strategy
- **THEN** the build does not spend time bootstrapping hermetic Perl when host Perl is available
- **AND** the target still builds successfully.

### Requirement: Strategy Must Be Documented and Operationally Controllable
The repository SHALL document the Perl strategy behavior, supported environments, and how to switch between host and hermetic modes.

#### Scenario: Operator can force hermetic fallback
- **GIVEN** an operator in a restricted environment
- **WHEN** they follow documented controls to enable hermetic fallback
- **THEN** the build uses hermetic Perl
- **AND** troubleshooting guidance includes rollback to default strategy.
