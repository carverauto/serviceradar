# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_sparse-v0.2.1...deep_causality_sparse-v0.2.2) - 2026-07-14

### Added

- *(deep_causality_haft)* add Category + Kleisli (named category, compose = bind) — H2

## [0.2.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_sparse-v0.2.0...deep_causality_sparse-v0.2.1) - 2026-07-08

### Added

- *(deep_causality_topology)* Add wall substrate - DCT transforms,

### Other

- *(num)* split deep_causality_num into num-core + algebra + complex + dual
- raise test coverage across 8 crates.
- Generated new SBOM for all crates.
- *(cfd)* finalize deep_causality_cfd + Flow DSL design and spec
- *(dec-solver)* projection CG warm-start + cycle-mean cylinder drag
- Updated README file across multiple crates to meet project standard.

## [0.2.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_sparse-v0.1.8...deep_causality_sparse-v0.2.0) - 2026-06-09

### Added

- *(deep_causality_tensor)* add logsumexp, gaussian log-density, conditional variance

### Other

- *(deep_causality)* fix rustdoc intra-doc link warnings
- *(sparse,topology)* lift cg_solve into deep_causality_sparse as public API
- cover map_values, EffectValue Display/PartialEq branches
- enforce repo-wide `unsafe_code = "forbid"`; remove avoidable unsafe

## [0.1.8](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_sparse-v0.1.7...deep_causality_sparse-v0.1.8) - 2026-05-26

### Added

- *(doc)* Consolidated all m examples in the dedicated example folder.
- *(deep_causality_sparse)* add feature-gated CausalTensor <-> CsrMatrix iso extension

### Other

- *(deep_causality_sparse)* improved test coverage.
- *(examples)* refactor iso examples.

## [0.1.7](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_sparse-v0.1.6...deep_causality_sparse-v0.1.7) - 2026-03-12

### Other

- Updated all SBOMS to reflect lates depdency versions.

## [0.1.6](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_sparse-v0.1.5...deep_causality_sparse-v0.1.6) - 2026-02-09

### Other

- updated all cargo dependencies to the latest version.

## [0.1.5](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_sparse-v0.1.4...deep_causality_sparse-v0.1.5) - 2026-01-22

### Other

- *(deep_causality_sparse)* Fixed  numerical instability bug.
- Updated SBOM of recently changed crates.

## [0.1.4](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_sparse-v0.1.3...deep_causality_sparse-v0.1.4) - 2026-01-09

### Added

- *(deep_causality_topology)* Implemented HKT traits for Gauge Field and related types.
- *(deep_causality_sparse)* Migrated to dedicted pure HKT trait.
- *(deep_causality_sparse)* Completed transition to GAT based HKT.
- *(deep_causality_sparse)* Finalized HKT extension to use new GAT bounded HKT.

### Other

- updated project wide SBOM files.
- updated project wide copyright note.

## [0.1.3](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_sparse-v0.1.2...deep_causality_sparse-v0.1.3) - 2025-12-31

### Other

- updated the following local packages: deep_causality_num

## [0.1.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_sparse-v0.1.1...deep_causality_sparse-v0.1.2) - 2025-12-18

### Fixed

- *(deep_causality_sparse)* Fixed a number of bugs. Updated tests for verification.

## [0.1.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_sparse-v0.1.0...deep_causality_sparse-v0.1.1) - 2025-12-12

### Added

- *(deep_causality_sparse)* Added HKT trait implementations for monadic composition.

### Other

- *(deep_causality_discovery)* Increased test coverage.
- *(deep_causality_sparse)* Increased test coverage.
- code formatting and linting

## [0.1.0](https://github.com/marvin-hansen/deep_causality/releases/tag/deep_causality_sparse-v0.1.0) - 2025-12-03

### Added

- *(deep_causality_sparse)* Fixing auto-release
- *(deep_causality_sparse)* Fixing auto-release
- *(deep_causality_sparse)* Fixed feature flag pass through
- *(deep_causality_sparse)* Fixed feature flag pass through for Bazel config.
- *(deep_causality_sparse)* Fixed feature flag pass through
- *(deep_causality_sparse)* Added full set of new algebraic trait system to CsrMatrix.
- *(deep_causality_sparse)* Added new specs for Algebraic structure of CsrMatrix.
- *(deep_causality_sparse)* refactored for performance improvements and code clarity.
- *(deep_causality_topology)* Added Manifold topology.
- *(deep_causality_sparse)* Implemented initial CsrMatrix types.
- *(deep_causality_sparse)* Implemented initial CsrMatrix types.

### Other

- Regenerated SBOM.
- Working on Bazel build config
- *(deep_causality_topology)* Added examples and debugging discrete differential geometry.
- *(deep_causality_topology)* implemented algebraic structure for Chain<T> in deep_causality_topology. Added new tests.
- *(deep_causality_spare)* Implement Contextual Sparsity and Algebraic traits for CsrMatrix<T> to support types that do not implement Zero (like CausalMultiVector) and enable topological computations.
- *(deep_causality_spare)* Refactored of code structures and applied various performance improvements.
- *(deep_causality_spare)* Applied various performance improvements.
- *(deep_causality_spare)* Added benchmark
- *(deep_causality_sparse)* Added SBOM.
- *(deep_causality_sparse)* Minor tweaks and lints. Removed unused trait bounds.
- *(deep_causality_sparse)* Updated Readme.
- *(deep_causality_sparse)* Added example, Readme, and some minor fixes.
- *(deep_causality_sparse)* tested  CsrMatrix types.
- *(deep_causality_sparse)* Documented CsrMatrix type.
