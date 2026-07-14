# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.9](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_core-v0.0.8...deep_causality_core-v0.0.9) - 2026-06-09

### Added

- *(deep_causality_core)* add the Causal Arrow + flow-DSL loops, branches, composition
- *(deep_causality_core)* add the CausalFlow fluent monad facade
- *(deep_causality_core)* add Alternatable trait family + refactor Intervenable to delegate

### Fixed

- resolve five P2 issues from the CI code review
- *(deep_causality_core)* align CausalFlow map/intervene_if with the monad's error-and-variant semantics
- *(deep_causality_core)* EffectLog equality compares messages, not timestamps

### Other

- Merge remote-tracking branch 'origin/main'
- *(deep_causality_core)* split the CausalFlow facade into submodules
- *(deep_causality_core)* split the CausalFlow facade into submodules
- *(num,haft,core)* close coverage gaps on Dual, Arrow builder, and CausalFlow
- *(deep_causality_core)* complete the CausalFlow channel-update family
- *(deep_causality_core)* Updated. Readme.
- - avionics_examples/cfd_taylor_green and turbulence_flow: the
- Migrated set of example to the arrow calculus type extension.
- cover map_values, EffectValue Display/PartialEq branches
- enforce repo-wide `unsafe_code = "forbid"`; remove avoidable unsafe
- *(deep_causality_core)* remove unused ControlFlowBuilder subsystem
- *(core)* apply use_self and const fn clippy lints

## [0.0.8](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_core-v0.0.7...deep_causality_core-v0.0.8) - 2026-05-29

### Added

- *(core)* add inherent error-safe fmap; sweep core examples to the fluent API

### Fixed

- *(deep_causality_core)* CausalMonad::bind returns None on error, not a fabricated default

### Other

- *(deep_causality_core)* replace value-only effect binds with one state-threading CausalMonad trait
- *(deep_causality_core)* relax over-specified Default bound on bind
- Merge branch 'deepcausality-rs:main' into main
- *(deep_causality_core)* Removed some dead code.

## [0.0.7](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_core-v0.0.6...deep_causality_core-v0.0.7) - 2026-05-26

### Other

- Updated example Readme.
- *(deep_causality_core)* pin Functor/Monad consistency between propagating-effect witnesses

## [0.0.6](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_core-v0.0.5...deep_causality_core-v0.0.6) - 2026-03-12

### Other

- Updated all SBOMS to reflect lates depdency versions.

## [0.0.5](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_core-v0.0.4...deep_causality_core-v0.0.5) - 2026-01-22

### Other

- *(deep_causality)* Fixed multipple bugs in Causaloid.
- *(deep_causality_core)* Fixed failing test.
- *(deep_causality_core)* Fixed Diamond bug.

## [0.0.4](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_core-v0.0.3...deep_causality_core-v0.0.4) - 2026-01-09

### Added

- *(deep_causality_core)* Migrated to dedicted pure HKT trait.
- *(deep_causality_core)* Finalized HKT extension to use new GAT bounded HKT.

### Other

- updated project wide SBOM files.
- updated project wide copyright note.

## [0.0.3](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_core-v0.0.2...deep_causality_core-v0.0.3) - 2025-12-31

### Other

- Updated SBOMs to trigger release.

## [0.0.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_core-v0.0.1...deep_causality_core-v0.0.2) - 2025-12-12

### Other

- *(deep_causality_core)* release v0.0.1

## [0.0.1](https://github.com/deepcausality-rs/deep_causality/releases/tag/deep_causality_core-v0.0.1) - 2025-12-12

### Added

- *(deep_causality_core)* enabled relase of crate.
- *(deep_causality_core)* Added bind_or_error to CausalEffectPropagationProcess
- *(deep_causality)* Updated extension tests to new API.
- *(deep_causality_core)* Removed unrelated types.
- *(deep_causality_core)* Re-implemented intervenable trait. Added new tests. Linting and code formatting.
- *(deep_causality)* Initial re-write using deep_causality_core crate for functional core.
- *(deep_causality_core)* Added test coverage
- *(deep_causality_num)* Added algebraic trait bounds.
- *(deep_causality_core)* Updated ControlFlowBuilder, Added new strict_zst examples, and updated CausalityError to be zero allocation.
- *(deep_causality_core)* Added ControlFlowBuilder, examples, and a README.md
- *(deep_causality_core)* First draft of new core crate

### Fixed

- fixed a number of Bazel config files.
- *(deep_causality)* Restored proper fn pointers in CausalFn and ContextualCausalFn.

### Other

- *(deep_causality_physics)* Code formatting and linting.
- *(deep_causality_physics)* Improved test coverage.
- *(deep_causality_physics)* Added more tests.
- *(deep_causality_physics)* Added more tests.
- Reorganized and updated repo wide examples.
- *(deep_causality_core)* Improved test coverage
- Regenerated SBOM.
- Fixed Bazel build config.
- *(deep_causality_core)* Improved test coverage
- *(deep_causality_core)* Improved test coverage
- *(deep_causality_core)* Improved test coverage
- Working on Bazel build config
- *(deep_causality_multivector)* Improved test coverage
- *(deep_causality_core)* Improved test coverage
- *(deep_causality_core)* Improved test coverage
- Updated Dev dependencies.
- Updated note on core type system design.
- Added note on hte preliminary design of the core crate.
- *(deep_causality_core)* Added Bazel configuration and some initial tests.
- *(deep_causality_core)* Added License and SBOM.
- *(deep_causality_core)* Separated CausalEffectPropagationProcess as a dedicated shared type for arity-3  PropagatingEffect and arity-5 PropagatingProcess.
- *(deep_causality_core)* Restructured code organization.
- *(deep_causality_core)* Lints and formatting.
- *(deep_causality_core)* Reworked Effect Log.
- *(deep_causality_core)* Fixed doctests.
