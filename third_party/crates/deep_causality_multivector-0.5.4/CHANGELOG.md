# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.4](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.5.3...deep_causality_multivector-v0.5.4) - 2026-07-14

### Added

- *(deep_causality_quantum)* the operator/channel layer on CausalTensor<Complex<R>> (Phase 2)

### Fixed

- *(deep_causality_multivector)* Minor fix
- *(deep_causality_multivector)* Code formatting
- *(deep_causality_physics)* Fixing 10MB max upload limit on crates.io

### Other

- *(miri)* ignore compute-heavy FFT/multivector tests; fix nextest period
- *(deep_causality_multivector)* updated README
- Improved test coverage.

## [0.5.3](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.5.2...deep_causality_multivector-v0.5.3) - 2026-07-08

### Added

- *(examples)* add example_ml_rca

### Other

- *(num)* split deep_causality_num into num-core + algebra + complex + dual
- *(bazel)* register all missing test suites; add Dual Default; move iso test utils to src/utils_tests
- raise test coverage across 8 crates.
- Generated new SBOM for all crates.
- *(papers)* Reorganized publication by moving each paper into the crate where it is actually implemented.
- Updated README file across multiple crates to meet project standard.

## [0.5.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.5.1...deep_causality_multivector-v0.5.2) - 2026-06-09

### Added

- *(num,multivector)* add Normed scalar trait; collapse per-scalar impls to blankets
- *(deep_causality_num)* split Real out of RealField

### Other

- Code formatting.
- Fixed unused dependencies across a number of crates.
- stabilize two more tests against Miri soft-float drift
- enforce repo-wide `unsafe_code = "forbid"`; remove avoidable unsafe

## [0.5.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.5.0...deep_causality_multivector-v0.5.1) - 2026-05-29

### Other

- updated the following local packages: deep_causality_core

## [0.5.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.4.2...deep_causality_multivector-v0.5.0) - 2026-05-26

### Added

- *(deep_causality_multivector, deep_causality_physics)* Generalize HilbertState/HopfState over R: RealField, no f64 defaults
- *(doc)* Consolidated all m examples in the dedicated example folder.
- *(deep_causality_multivector)* add structural iso between CausalMultiField and its tuple carrier

### Fixed

- *(deep_causality_physics, deep_causality_multivector)* Address review feedback on the precision-parametric refactor

## [0.4.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.4.1...deep_causality_multivector-v0.4.2) - 2026-03-12

### Other

- Updated all SBOMS to reflect lates depdency versions.

## [0.4.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.4.0...deep_causality_multivector-v0.4.1) - 2026-02-09

### Other

- updated the following local packages: deep_causality_num

## [0.4.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.3.0...deep_causality_multivector-v0.4.0) - 2026-01-22

### Added

- *(deep_causality_multivector)* Applied lints and fixes.
- *(deep_causality_multivector)* Increased test coverage.
- *(deep_causality_tensor)* Finalized MLX removal.
- *(deep_causality_tensor)* Removed MLX backed.
- *(deep_causality_topology)* Removed MLX backed.
- *(deep_causality_multivector)* Updated tests and applied lints & fixes.
- *(deep_causality_multivector)* Removed MLX backed.

### Other

- *(deep_causality_num)* Renamed DoubleFloat to Float106 for consistency with existing float types.
- *(deep_causality_discovery)* Fixed numerous bugs.
- *(deep_causality_multivector)* Fixed a number of bugs.
- remoced unneccessary trait bounds.
- Updated SBOM of and applied docstring fixes.
- Updated SBOM of recently changed crates.

## [0.3.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.2.5...deep_causality_multivector-v0.3.0) - 2026-01-09

### Added

- *(deep_causality_physics)* Renamed qed to electromagnetism. Fixed a number of issues and updated example.
- *(deep_causality_multivector)* Migrated to dedicted pure HKT trait.
- *(deep_causality_multivector)* Completed transition to GAT based HKT.

### Other

- Updated Bazel build and test config.
- updated project wide SBOM files.
- updated project wide copyright note.
- Removed unused feature flag.

## [0.2.5](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.2.4...deep_causality_multivector-v0.2.5) - 2025-12-31

### Other

- updated the following local packages: deep_causality_core

## [0.2.4](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_multivector-v0.2.3...deep_causality_multivector-v0.2.4) - 2025-12-31

### Added

- *(deep_causality_tensor)* Applied multiple lints, fixes, and code improvements.
- *(deep_causality_tensor)* Applied multiple lints, fixes, and code improvements.
- *(deep_causality_multivector)* separated MLX code into dedicted files for better maintainabiliy.
- *(deep_causality_multivector)* Increased test coverage.
- *(deep_causality_multivector)* Increased test coverage.
- *(deep_causality_tensor)* Increased test coverage.
- *(deep_causality_multivector)* Added HKT like implementation to CausalMultiFied.
- *(deep_causality_multivector)* Added algebraic trait impl for MultiField.
- *(deep_causality_multivector)* Updated and fixed sample code.
- *(deep_causality_multivector)* Updated Benchmarks.
- *(deep_causality_multivector)* Consolidated API in a single file.
- *(deep_causality_multivector)* Added test coverage for the new MultiField type.
- *(deep_causality_multivector)* Added MLX acceleation; added new MultiField type with MLX acceleration.
- *(deep_causality_metric)* Integrated new metric crate across the repo.

### Other

- Lots of lints, formatting, and minor fixes.
- Lots of lints, formatting, and minor fixes.
- Updated keywords in Cargo.toml
- Add new specification for cross crate hardware acceleration...

## [0.2.3](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.2.2...deep_causality_multivector-v0.2.3) - 2025-12-18

### Other

- updated the following local packages: deep_causality_num

## [0.2.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.2.1...deep_causality_multivector-v0.2.2) - 2025-12-14

### Other

- *(deep_causality_multivector)* Increased test coverage.

## [0.2.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.2.0...deep_causality_multivector-v0.2.1) - 2025-12-12

### Other

- updated the following local packages: deep_causality_core

## [0.2.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.1.3...deep_causality_multivector-v0.2.0) - 2025-12-12

### Added

- *(deep_causality_multivector)* Removed all quantum code as it has moved into the physics crate.
- *(deep_causality_multivector)* Added new normalize_l2 and norm_l2 as well as modulus_squared and scale_by_real methods to CausalMultiVector.
- *(deep_causality_multivector)* Added some notes on the examples.
- *(deep_causality_multivector)* Added new example: Optimal Estimation of the Gravity Vector
- *(deep_causality_multivector)* Code refactoring for improved structure.
- *(deep_causality_multivector)* Added HopfState. Added reference arithmetic. Added two new examples, maxwell and hopf fibration.

### Fixed

- fixed a number of Bazel config files.
- *(deep_causality_multivector)* Lints and code improvements.
- *(deep_causality_multivector)* Lints and code improvements.

### Other

- Added two new physics exmples.
- *(deep_causality_physics)* Added various bound checks and other checks to ensure correct math.
- *(deep_causality_physics)* Improved test coverage.
- *(deep_causality_multivector)* Added Multivector Arithmetic Tests for assignment operators.
- *(deep_causality_multivector)* Added default to hilbert state.
- *(deep_causality_multivector)* Improved test coverage.
- *(deep_causality_multivector)* code formatting.
- *(deep_causality_multivector)* Improved test coverage.

## [0.1.3](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_multivector-v0.1.2...deep_causality_multivector-v0.1.3) - 2025-12-03

### Added

- *(deep_causality_sparse)* Fixing auto-release
- *(deep_causality_num)* Increased test coverage.
- *(deep_causality_sparse)* Added full set of new algebraic trait system to CsrMatrix.
- *(deep_causality_tensor)* Added full set of new algebraic trait system to CausalTensor.
- *(deep_causality_multivector)* Minor code re-organization.
- *(deep_causality_num)* Added market traits for Associative, Distributive, and Commutative. Updated algebra traits accordingly and fixed downstream.
- *(deep_causality_multivector)* Added full set of new algebraic trait system to CausalMultiVector.
- *(deep_causality_multivector)* Ported CausalMultiVector to use Field instead of the broader Num trait to ensure correct math.
- *(deep_causality_num)* Update all tests for Complex Number type with proper algebraic traits.
- *(deep_causality_topology)* Initial implementation of topology data structures.

### Other

- Regenerated SBOM.
- *(deep_causality_multivector)* Improved test coverage
- Updated dev dependencies across the repo.
- Updated Dev dependencies.
- *(deep_causality_topology)* Added test coverage.
- *(deep_causality_multivector)* Added implementation of BoundedAdjunction trait as type extension.
- *(deep_causality_haft)* Added BoundedAdjunction trait.
- Merge branch 'deepcausality-rs:main' into main
- Merge remote-tracking branch 'origin/main'
- Restored manually generated SBOM to restore Dependency and licence scan.

## [0.1.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.1.1...deep_causality_multivector-v0.1.2) - 2025-11-23

### Other

- Merge branch 'deepcausality-rs:main' into main

### Removed

- removed all manually generated SBOM files

## [0.1.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_multivector-v0.1.0...deep_causality_multivector-v0.1.1) - 2025-11-23

### Added

- *(deep_causality_multivector)* Minor lints.
- *(deep_causality_multivector)* Added General Relativistic Magnetohydrodynamics example
- *(deep_causality_multivector)* Added General Relativistic Magnetohydrodynamics example
- *(deep_causality_multivector)* Updated README.md
- *(deep_causality_multivector)* Added new example.
- *(deep_causality_multivector)* Added new example.
- *(deep_causality_multivector)* Updated README.md
- *(deep_causality_multivector)* Added benchmark for quantum ops
- *(deep_causality_multivector)* Added quantum example via Hilbert State
- *(deep_causality_multivector)* Minor lints
- *(deep_causality_multivector)* Added quantum gate and operation extension.
- *(deep_causality_multivector)* Added commutator_lie and commutator_geometric operations to API.
- *(deep_causality_multivector)* refactored core API as a trait.
- *(deep_causality_multivector)* Added BoundedComonad impl as type extension.
- *(deep_causality_multivector)* Added SBOM to multivector crate.

### Other

- *(deep_causality_multivector)* improved test coverage.
- *(deep_causality_multivector)* improved test coverage.
- *(deep_causality_multivector)* improved performance of geometric product on for sparse and dense cases.
- *(deep_causality_multivector)* Fixed incorrect basis_shift.
- *(deep_causality_multivector)* Fixed incorrect extend impl and fixed some tests.
- *(deep_causality_num)* Added test coverage for Octonion numbers.
- *(deep_causality_multivector)* Increased test coverage
- *(deep_causality_multivector)* Fixed tests.
- *(deep_causality_multivector)* Improved test coverage and added minor lints and fixes.
- *(deep_causality_multivector)* Fixed some complex algebras, added Euclidean algebra, added constructor aliases, and split algebras.
