# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.4.0...deep_causality_haft-v0.4.1) - 2026-07-14

### Added

- *(haft)* add more tests.
- *(haft)* add EqFunctor/DebugFunctor capability traits + opt-in Eq/Debug for Free
- *(deep_causality)* the graph algebra — schedule-invariant ∇∘(Λ⊗Λ) joins + freeze checks (roadmap Stage 4)
- *(deep_causality_haft)* symmetric-monoidal PROP — Δ/ε, ∇/η, σ (H5)
- *(deep_causality_haft)* one-way interpreter ArrowTerm → Kleisli<M> (H4)
- *(deep_causality_haft)* reified free Arrow — ArrowTerm (H3)
- *(deep_causality_haft)* add Category + Kleisli (named category, compose = bind) — H2
- *(haft)* add Foldable::fold_map (monoidal fold) — H1 of haft-categorical-machinery

### Fixed

- *(deep_causality_haft)* Signed-off-by: Marvin Hansen <marvin.hansen@gmail.com>
- *(deep_causality_physics)* Fixing 10MB max upload limit on crates.io

### Other

- *(openspec)* propose haft Cofree comonad twin + opt-in Eq/Debug (capability traits)
- Improved test coverage.
- drop Aeneas / L4 from the verification program (non-goal)

## [0.4.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.3.3...deep_causality_haft-v0.4.0) - 2026-07-08

### Added

- *(haft)* add the free monad on a functor (algebraic-effects base)
- *(formalization)* formalize deep_causality_haft in Lean + mirrored Rust witnesses
- *(deep_causality_haft)* formatting
- *(deep_causality_haft)* add lazy IoAction effect (the Arrow twin)
- *(deep_causality_haft)* To reorganize source code structure

### Fixed

- *(haft)* [**breaking**] align law docs with proved theory; make effect-system reference impl lawful

### Other

- *(num)* split deep_causality_num into num-core + algebra + complex + dual
- *(bazel)* register all missing test suites; add Dual Default; move iso test utils to src/utils_tests
- Code formatting and linting.
- Fixed multiple issues in the HAFT formalization.
- *(core)* [**breaking**] enforce the W-invariant — value-XOR-error as one channel
- chorde(deep_causality_haft); reorganized source code
- Generated new SBOM for all crates.
- Updated README file across multiple crates to meet project standard.

## [0.3.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.3.1...deep_causality_haft-v0.3.2) - 2026-05-26

### Fixed

- *(deep_causality_num)* added three-tier isomorphism trait family across num and haft

### Other

- *(deep_causality_physics)* Restructure tests tree to mirror src/kernels/ layout; update Bazel

## [0.3.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.3.0...deep_causality_haft-v0.3.1) - 2026-03-12

### Other

- Updated all SBOMS to reflect lates depdency versions.

## [0.3.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.2.7...deep_causality_haft-v0.3.0) - 2026-01-09

### Added

- *(deep_causality_haft)* Added alias for common traits to simplify usage and restructured internal code.
- *(deep_causality_haft)* Fixed some tests. Removed dependeny on num.
- *(deep_causality_haft)* Seperated Pure into dedicated Trait to enable Monad implementation without Applicative.
- *(deep_causality_haft)* Completed transition to GAT based HKT.
- *(deep_causality_haft)* Removed legacy trait bound support.
- *(deep_causality_tensor)* Upated HKT extension to use new GAT bounded HKT.
- *(deep_causality_haft)* Finalized implementaion of GAT bounded HKT.
- *(deep_causality_haft)* Completed initial implementaion of GAT bounded HKT.
- *(deep_causality_haft)* Iniital implementaion of GAT bounded HKT.

### Other

- *(deep_causality_haft)* increased test coverage.
- updated project wide SBOM files.
- updated project wide copyright note.

## [0.2.7](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_haft-v0.2.6...deep_causality_haft-v0.2.7) - 2025-12-31

### Other

- updated the following local packages: deep_causality_num

## [0.2.6](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.2.5...deep_causality_haft-v0.2.6) - 2025-12-18

### Other

- updated the following local packages: deep_causality_num

## [0.2.5](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_haft-v0.2.4...deep_causality_haft-v0.2.5) - 2025-12-03

### Added

- *(deep_causality_sparse)* Fixing auto-release
- *(deep_causality_core)* Added test coverage
- *(deep_causality_topology)* Initial implementation of topology data structures.
- *(deep_causality)* Moved LogAppend trait into haft crate.
- *(deep_causality_haft)* Updated Readme with details on non-std builds.
- *(deep_causality_haft)* Added support for non-std.
- *(deep_causality_haft)* Added module documentation
- *(deep_causality_haft)* Refactored source code structure of the HAFT crate.
- *(deep_causality_haft)* Added new examples for the HAFT crate.
- *(deep_causality_haft)* Improved existing examples for the HAFT crate.
- *(deep_causality_haft)* Implement Unbound HKTs, N-Arity traits, and

### Other

- Regenerated SBOM.
- *(deep_causality_core)* Lints and formatting.
- *(deep_causality_core)* Reworked Effect Log.
- *(deep_causality_core)* Fixed doctests.
- *(deep_causality_haft)* Added BoundedAdjunction trait.
- *(deep_causality_haft)* Updated Bazel config
- *(deep_causality_haft)* Code formatting.
- *(deep_causality_haft)* Removed flaky tests
- *(deep_causality_haft)* Added and update test suite to cover all newly added types and traits.
- Merge branch 'deepcausality-rs:main' into main
- Merge remote-tracking branch 'origin/main'
- Restored manually generated SBOM to restore Dependency and licence scan.

## [0.2.4](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.2.3...deep_causality_haft-v0.2.4) - 2025-11-23

### Other

- Merge branch 'deepcausality-rs:main' into main

### Removed

- removed all manually generated SBOM files

## [0.2.3](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.2.2...deep_causality_haft-v0.2.3) - 2025-11-23

### Added

- *(deep_causality_haft)* Added BoundedComonad for usage with MultiVector.
- *(deep_causality_tensor)* Implemented CoMonad for Causaltensor
- *(deep_causality_haft)* Added CoMonad and Traversable trait for HKT. Added default implementations for some std types. Added examples, tests and documentation.
- *(deep_causality_haft)* Introduced Default trait bound to MonadEffect types to simplify error case handling. Update downstream deps.

### Fixed

- *(deep_causality_haft)* Fixed trait bound inconsistency in default impl for Option and Result.

### Other

- Updated Bazael config
- Merge branch 'deepcausality-rs:main' into main

## [0.2.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.2.1...deep_causality_haft-v0.2.2) - 2025-11-05

### Other

- Updated SBOM for all crates.

## [0.2.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.2.0...deep_causality_haft-v0.2.1) - 2025-10-31

### Added

- *(deep_causality_tensor)* Added Higher Kinded Type extension.
- *(deep_causality_haft)* Added more default witness types and updated example code.
- *(deep_causality_haft)* Added more default witness types and updated example code.
- *(deep_causality_haft)* Added SBOM and signature

### Other

- *(deep_causality_haft)* Updated README.md

## [0.2.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_haft-v0.1.0...deep_causality_haft-v0.2.0) - 2025-10-19

### Added

- *(deep_causality_haft)* Updated Bazel config.
- *(deep_causality_haft)* Added new example and updated README.md
- *(deep_causality_haft)* Added Foldable trait with tests.
- *(deep_causality_haft)* Added Applicative trait with tests.
- *(deep_causality_haft)* Added HKT Trait for Arity 5 together with Monad and MonadEffect for HKT5. Refactored code based. Added HKT type extension for Vec.
- *(deep_causality_haft)* Added HKT Trait for Arity 4 together with Monad and MonadEffect for HKT4

### Other

- Merge remote-tracking branch 'origin/main'
- *(deep_causality_haft)* Added extensive documentation.
- *(deep_causality_haft)* Increased test coverage.
