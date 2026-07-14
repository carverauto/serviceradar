# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.4.0...deep_causality_num-v0.4.1) - 2026-07-14

### Added

- *(deep_causality_haft)* add Category + Kleisli (named category, compose = bind) — H2

### Fixed

- *(deep_causality_num)* use core::num::FpCategory; wire haft no_std

### Other

- *(miri)* ignore compute-heavy FFT/multivector tests; fix nextest period
- drop Aeneas / L4 from the verification program (non-goal)
- *(num)* add crate-local Lean verification status notes for the numeric tower
- *(openspec)* close out formalize-main-crate — main-crate Lean status note, sync + archive

## [0.4.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.3.3...deep_causality_num-v0.4.0) - 2026-07-08

### Added

- *(lean)* formalize the extracted num/algebra/complex/dual crates (L1)
- *(deep_causality_num)* generic monoid tower + verdict carrier (num-generic-monoid-tower)
- *(deep_causality_num)* Added default to dual type.
- *(deep_causality_num,deep_causality_tensor)* complex-capable SVD/QR kernels via ConjugateScalar
- *(deep_causality_tensor)* tensor-network Stage 1 — CausalTensorTrain (MPS) state
- *(deep_causality_num)* double-double erf/erfc for Float106

### Fixed

- *(formalization)* repair Lean Core build + review follow-ups
- *(deep_causality_num)* Fixed miri test config
- *(deep_causality_num)* Fixed miri test config
- *(deep_causality_num)* Fixed miri test config
- *(deep_causality_num)* Fixed miri test config

### Other

- *(num)* split deep_causality_num into num-core + algebra + complex + dual
- *(bazel)* register all missing test suites; add Dual Default; move iso test utils to src/utils_tests
- *(formalization)* scaffold Lean proof project + Rust witness bridge
- *(deep_causality_num)* [**breaking**] remove unused EuclideanDomain trait
- *(deep_causality_tensor)* tensor-network — document Stage-4 scalar generality
- *(deep_causality_num)* restructured internal code modules.
- Generated new SBOM for all crates.
- *(deep_causality_num)* skip cos_val under Miri
- Updated README file across multiple crates to meet project standard.
- *(deep_causality_num)* Add table-based fast path for Float106::sin_cos

## [0.3.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.3.1...deep_causality_num-v0.3.2) - 2026-05-26

### Added

- *(deep_causality_num)* Updated design specs and documentation.
- *(deep_causality_num)* add Tier 2 witness-typed Iso traits + StandardIso (iso-traits Stage B)
- *(deep_causality_num)* Fixed six pre-existing bugs in unrelated code that were blocking no_std;
- *(deep_causality_num)* add Tier 1 isomorphism marker subtraits (iso-traits Stage A)

### Fixed

- *(deep_causality_num)* added three-tier isomorphism trait family across num and haft
- *(deep_causality_num)* check witness/From round-trip in both directions independently

### Other

- skip 4 more transcendental float tests under Miri
- *(deep_causality_num)* skip transcendental float tests under Miri
- code formatting and linting.
- *(deep_causality_num)* improve test coverage.

## [0.3.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.3.0...deep_causality_num-v0.3.1) - 2026-03-12

### Other

- Updated all SBOMS to reflect lates depdency versions.

## [0.3.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.2.0...deep_causality_num-v0.3.0) - 2026-02-09

### Other

- *(deep_causality_num)* Added is_nan, is_infinite, and is_finite to Float106 type

## [0.2.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.1.12...deep_causality_num-v0.2.0) - 2026-01-22

### Other

- *(deep_causality_num)* Renamed DoubleFloat to Float106 for consistency with existing float types.
- *(deep_causality_num)* Renamed DoubleFloat to Float106 for consistency with existing float types.
- *(deep_causality_num)* Fixed Complex::powi bug where negative exponents produced incorrect results.
- *(deep_causality_num)* Tested asin, acos, and atan tests to increase test coverage.
- *(deep_causality_num)* Added asin impl to RealField and default impl.
- Merge remote-tracking branch 'origin/main'
- Fixed and lints.
- *(deep_causality_num)* Added atan impl to RealField and default impl.
- *(deep_causality_topology)* Added first example that verifies the correctness of the Lattice Gaugle Field up to 1e-31(!)

## [0.1.12](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.1.11...deep_causality_num-v0.1.12) - 2026-01-09

### Added

- *(deep_causality_num)* Updated module structure
- *(deep_causality_num)* Added some more algebra traits.
- *(deep_causality_num)* Added integer trait and default impl.
- *(deep_causality_num)* Refactored code structure of DoubleFloat type.
- *(deep_causality_physics)* Completed integration of new DoubleFloat Type.
- *(deep_causality_num)* Code formatting.
- *(deep_causality_num)* Initial implementation of DoubleFloat type.
- *(deep_causality_num)* Added specs for High-Precision DoubleFloat.

### Fixed

- *(deep_causality_num)* Fixed numerical instability in transcedental operations at the 30/21 digit.

### Other

- Updated Bazel build and test config.
- repo wide lints and fixes
- *(deep_causality_physics)* increased test coverage.
- repo wide lints and formatting.
- *(deep_causality_num)* increased test coverage.
- updated project wide SBOM files.
- updated project wide copyright note.

## [0.1.11](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_num-v0.1.10...deep_causality_num-v0.1.11) - 2025-12-31

### Added

- *(deep_causality_multivector)* Updated and fixed sample code.

## [0.1.10](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.1.9...deep_causality_num-v0.1.10) - 2025-12-18

### Fixed

- *(deep_causality_num)* Fixed a number of bugs. Updated tests for verification.

## [0.1.9](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_num-v0.1.8...deep_causality_num-v0.1.9) - 2025-12-03

### Added

- *(deep_causality_sparse)* Fixed feature flag pass through for Bazel config.
- *(deep_causality_num)* Simplified Algebra bounds of complex number systems.
- *(deep_causality_num)* Increased test coverage.
- *(deep_causality_num)* code refactoring
- *(deep_causality_num)* Increased test coverage.
- *(deep_causality_num)* Increased test coverage.
- *(deep_causality_num)* Turned runtime checks of feat flags into compiler errors.
- *(deep_causality_num)* Updated copyright note across the entire crate.
- *(deep_causality_num)* Added native rotation to Complex, Quaternion, and Octonions
- *(deep_causality_num)* Documented Octonion Number type with proper algebraic traits. Updated tests.
- *(deep_causality_num)* Re-implemented Octonion Number type with proper algebraic traits. Updated tests.
- *(deep_causality_num)* Re-implemented Quaternion Number type with proper algebraic traits. Updated tests.
- *(deep_causality_num)* Added market traits for Associative, Distributive, and Commutative. Updated algebra traits accordingly and fixed downstream.
- *(deep_causality_multivector)* Added full set of new algebraic trait system to CausalMultiVector.
- *(deep_causality_multivector)* Ported CausalMultiVector to use Field instead of the broader Num trait to ensure correct math.
- *(deep_causality_num)* Update all tests for Complex Number type with proper algebraic traits.
- *(deep_causality_num)* Re-implemented Complex Number type with proper algebraic traits.
- *(deep_causality_num)* Added missing default impl for inverse in Field trait.
- *(deep_causality_num)* Updated algebraic traits and added comprehensive documentation.
- *(deep_causality_num)* Updated algebraic traits.
- *(deep_causality_num)* Added algebraic trait bounds.
- *(deep_causality_num)* Updated Readme with information for non-std builds.
- *(deep_causality_num)* Updated Readme with information for non-std builds.
- *(deep_causality_num)* Updated Readme with information for non-std builds.
- *(deep_causality_num)* Added support for non-std.

### Other

- Regenerated SBOM.
- Fixed Bazel build config.
- *(deep_causality_num)* Increased test coverage.
- Updated all vendored deps for Bazel.
- Merge branch 'deepcausality-rs:main' into main
- Merge remote-tracking branch 'origin/main'
- Restored manually generated SBOM to restore Dependency and licence scan.

## [0.1.8](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.1.7...deep_causality_num-v0.1.8) - 2025-11-23

### Other

- Merge branch 'deepcausality-rs:main' into main

### Removed

- removed all manually generated SBOM files

## [0.1.7](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.1.6...deep_causality_num-v0.1.7) - 2025-11-23

### Added

- *(deep_causality_multivector)* Added quantum gate and operation extension.
- *(deep_causality_num)* Added documentation to Octonion implementation.
- *(deep_causality_num)* Added Octonion implementation.
- *(deep_causality_num)* Fixed doct tests
- *(deep_causality_num)* Reorganized internal source code.

### Other

- *(deep_causality_num)* Minor lint
- *(deep_causality_num)* Minor lint
- *(deep_causality_num)* Added test coverage for Octonion numbers.
- *(deep_causality_num)* Added test utils for Octonion testing

## [0.1.6](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.1.5...deep_causality_num-v0.1.6) - 2025-11-05

### Added

- *(deep_causality_num)* This change introduces a new Quaternion type accompanied by a comprehensive suite.

### Fixed

- *(deep_causality_num)* Minor fixes and lints.
- *(deep_causality_num)* The Display implementation for Quaternion has been refined to correctly handle the signs of its components, producing a more standard and readable mathematical format. All tests pass.
- *(deep_causality_num)* The slerp implementation has been corrected by removing the incorrect special case for antipodal quaternions and adding a check for nearly identical quaternions to use linear interpolation, preventing division by
- *(deep_causality_num)* The scalar division implementation has been refactored to align with Rust's standard floating-point division-by-zero behavior, which produces
- *(quaternion)* The scalar division implementation has been refactored to align with Rust's standard floating-point division-by-zero behavior, which produces

### Other

- Updated Bazel config. Applied minor lint.
- *(quaternion)* Added docstring to all public API methods.
- Updated README
- *(quaternion)* Address test inaccuracies and revert slerp regression. Added rotation methods and tests.
- Updated SBOM for all crates.

## [0.1.5](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.1.4...deep_causality_num-v0.1.5) - 2025-10-31

### Added

- *(deep_causality)* Added ComplexTensor to PropagatingEffect.
- *(deep_causality_num)* Introduce Complex<F> type and ComplexNumber trait.

### Other

- *(deep_causality_num)* increased test coverage.
- *(deep_causality_num)* Added Numerically stable principal sqrt
- *(deep_causality_num)* minor fixes.
- *(deep_causality_num)* increased test coverage.
- *(deep_causality_num)* increased test coverage.
- *(deep_causality_num)* increased test coverage.

## [0.1.3](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.1.2...deep_causality_num-v0.1.3) - 2025-09-25

### Other

- Updated SBOM for all crates.
- Updated SBOM for all crates.

## [0.1.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.1.1...deep_causality_num-v0.1.2) - 2025-09-22

### Fixed

- *(deep_causality)* Removed last internal macros and removed dependency on deep_causality_macro crate.

### Other

- Updated SBOM script to generate hash signature together with the SBOM.

## [0.1.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_num-v0.1.0...deep_causality_num-v0.1.1) - 2025-09-21

### Other

- Updated Cargo configuration and feature propagation across the entire repo.
