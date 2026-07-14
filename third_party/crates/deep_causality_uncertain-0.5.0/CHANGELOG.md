# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.4.0...deep_causality_uncertain-v0.5.0) - 2026-07-14

### Added

- *(deep_causality)* the graph algebra — schedule-invariant ∇∘(Λ⊗Λ) joins + freeze checks (roadmap Stage 4)

### Fixed

- *(deep_causality_physics)* Fixing 10MB max upload limit on crates.io

### Other

- strengthen arrow_choice witnesses; fix archived-note paths; clarify Lean scope —
- Improved test coverage.

## [0.4.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.16...deep_causality_uncertain-v0.4.0) - 2026-07-08

### Added

- *(deep_causality_uncertain)* QmcSampler as an alternative Sampler
- *(deep_causality_uncertain)* deterministic sampler seeding (seed_sampler / clear_sampler_seed)
- *(deep_causality_uncertain)* Generalize the uncertain engine over RealField (Float106)

### Fixed

- *(deep_causality_uncertain)* Fixed miri test config
- *(deep_causality_uncertain)* Fixed miri test config
- *(deep_causality_uncertain)* Fixed miri test config

### Other

- *(num)* split deep_causality_num into num-core + algebra + complex + dual
- *(bazel)* register all missing test suites; add Dual Default; move iso test utils to src/utils_tests
- raise test coverage across 8 crates.
- Generated new SBOM for all crates.
- *(papers)* Reorganized publication by moving each paper into the crate where it is actually implemented.
- *(deep_causality_uncertain)* QmcSampler::new takes &Uncertain<T>; root_node() is crate-internal
- *(deep_causality_uncertain)* Generalize the lift, sampling, and statistics surface over the value type
- *(deep_causality_uncertain)* Make lift_to_uncertain generic over ProbabilisticType
- Updated README file across multiple crates to meet project standard.

## [0.3.16](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.15...deep_causality_uncertain-v0.3.16) - 2026-06-09

### Other

- enforce repo-wide `unsafe_code = "forbid"`; remove avoidable unsafe

## [0.3.15](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.14...deep_causality_uncertain-v0.3.15) - 2026-05-26

### Other

- *(examples)* rewrite uncertain examples as monadic chains and move into causal_uncertain_examples
- skip 4 more transcendental float tests under Miri
- *(deep_causality_uncertain)* skip rusty-fork modules under Miri
- Code formatting.
- Added new benchmark to maybe uncertain type.

## [0.3.14](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.13...deep_causality_uncertain-v0.3.14) - 2026-03-12

### Other

- Updated all SBOMS to reflect lates depdency versions.

## [0.3.13](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.12...deep_causality_uncertain-v0.3.13) - 2026-02-09

### Other

- updated all cargo dependencies to the latest version.

## [0.3.12](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.11...deep_causality_uncertain-v0.3.12) - 2026-01-22

### Other

- *(deep_causality_uncertain)* Fixed Monte Carlo Sampling bug.

## [0.3.11](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.10...deep_causality_uncertain-v0.3.11) - 2026-01-09

### Other

- updated project wide SBOM files.
- updated project wide copyright note.

## [0.3.10](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_uncertain-v0.3.9...deep_causality_uncertain-v0.3.10) - 2025-12-31

### Other

- updated the following local packages: deep_causality_num

## [0.3.9](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.8...deep_causality_uncertain-v0.3.9) - 2025-12-18

### Other

- updated the following local packages: deep_causality_num

## [0.3.8](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.7...deep_causality_uncertain-v0.3.8) - 2025-12-12

### Other

- Updated criterion across the repo.

## [0.3.7](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_uncertain-v0.3.6...deep_causality_uncertain-v0.3.7) - 2025-12-03

### Added

- *(deep_causality_sparse)* Fixing auto-release

### Other

- Regenerated SBOM.
- Updated dev dependencies across the repo.
- Updated Dev dependencies.
- Merge branch 'deepcausality-rs:main' into main
- Merge remote-tracking branch 'origin/main'
- Restored manually generated SBOM to restore Dependency and licence scan.

## [0.3.6](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.5...deep_causality_uncertain-v0.3.6) - 2025-11-23

### Other

- Merge branch 'deepcausality-rs:main' into main

### Removed

- removed all manually generated SBOM files

## [0.3.5](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.4...deep_causality_uncertain-v0.3.5) - 2025-11-23

### Added

- *(deep_causality)* Refactor PropagatingEffect and Causaloid.

### Other

- Merge branch 'deepcausality-rs:main' into main

## [0.3.4](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.3...deep_causality_uncertain-v0.3.4) - 2025-11-05

### Added

- *(deep_causality_uncertain)* Migrated internal compute graph to ConsTree from deep_causality_ast crate.
- *(ast)* Add deep_causality_ast crate with persistent tree

### Other

- Updated SBOM for all crates.
- *(deep_causality_uncertain)* Increased test coverage.
- Trying a new approach for HKT traits and extensions for Uncertain type
- Trying a new approach with HKT-like traits with type bounds.
- Removed extensions from uncertain crate
- Merge branch 'deepcausality-rs:main' into 008-hkt-uncertain-specs
- ✦ feat(uncertain): Implement Higher-Kinded Types
- Added specs for HKT uncertain types.

## [0.3.3](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.2...deep_causality_uncertain-v0.3.3) - 2025-10-31

### Added

- *(deep_causality_uncertain)* Added type aliases
- *(deep_causality)* Added MaybeUncertain and CausalTensor to PropagatingEffect. Updated tests.

### Other

- *(deep_causality_uncertain)* Increased test coverage.
- *(deep_causality_uncertain)* Increased test coverage.
- Added and updated type aliases.

## [0.3.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.1...deep_causality_uncertain-v0.3.2) - 2025-10-19

### Other

- *(deps)* Bump rusty-fork from 0.3.0 to 0.3.1

## [0.3.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.3.0...deep_causality_uncertain-v0.3.1) - 2025-10-02

### Added

- *(deep_causality_discovery)* working on data cleaning step during CDL

### Other

- *(deep_causality_uncertain)* removed flaky test assertion.

## [0.3.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.2.3...deep_causality_uncertain-v0.3.0) - 2025-09-25

### Added

- *(deep_causality_uncertain)* Updated Readme and examples.
- *(deep_causality_uncertain)* introduce MaybeUncertain type for probabilistic presence

### Other

- Updated SBOM for all crates.
- Minor lints and fixes. Trying cargo cache on build and test.
- Updated SBOM for all crates.

## [0.2.3](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.2.2...deep_causality_uncertain-v0.2.3) - 2025-09-22

### Fixed

- *(deep_causality)* Removed last internal macros and removed dependency on deep_causality_macro crate.

### Other

- Updated SBOM script to generate hash signature together with the SBOM.

## [0.2.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.2.1...deep_causality_uncertain-v0.2.2) - 2025-09-21

### Added

- *(deep_causality_num)* Initial implementation. Update of all downstream crates.
- *(deep_causality_rand)* Fixed issue with std pseudo number generator. Updated upstream crate deep_causality_uncertain
- *(deep_causality_uncertain)* Migrated random number generation to deep_causality_rand crate

### Fixed

- *(deep_causality_uncertain)* Minor test fix.
- *(deep_causality_uncertain)* Minor linting and formatting

### Other

- Updated Cargo configuration and feature propagation across the entire repo.
- Reworked and updated Bazel test config across all crates.
- Lots of lints and formats. Updated MSRV to 1.89 and edition 2024 across the entire repo.
- *(deep_causality_rand)* Increased test coverage.
- Added or updated Bazel config for the newly added crates.
- Updated build scripts

## [0.2.1](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_uncertain-v0.2.0...deep_causality_uncertain-v0.2.1) - 2025-09-11

### Other

- trying to fix #315
- trying to fix #315
- trying to fix #315
- trying to fix #315
- trying to fix #315
- trying to fix #315
- trying to fix #315
- Fixed dependencies in the Uncertain crate to resolve #315
- Fixed global Cargo.toml to resolve #315
- Fixed dependencies in the Uncertain crate to resolve #315
- Updated project wide Bazel config, removed Bazel aliases, and updated project wide macro imports from the deep_causality_macro crate.

## [0.2.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_uncertain-v0.1.0...deep_causality_uncertain-v0.2.0) - 2025-09-08

### Added

- *(deep_causality_uncertain)* Increased test coverage.
- *(deep_causality_uncertain)* Increased test coverage.
- *(deep_causality_uncertain)* Improved uncertain_f64 with estimate_probability_exceeds and uncertain_bool with to_bool
- *(deep_causality_uncertain)* implemented PartEq for ComputationalNode. Added identity checks to ComputationalNode. Re-organized code and imports.
- *(deep_causality)* Add uncertain data types and tests to DeepCausality
- *(deep_causality_uncertain)* Implemented Debug for Uncertain and ComputationNode type.

### Fixed

- *(deep_causality_uncertain)* Fixed flaky test

### Other

- Increased test coverage across all crates.
- Increased test coverage across all crates.
- Updated project wide Bazel config.
- Merge remote-tracking branch 'origin/main'
# Changelog
