# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.2.0...deep_causality_rand-v0.2.1) - 2026-07-14

### Added

- *(deep_causality_haft)* add Category + Kleisli (named category, compose = bind) — H2

## [0.2.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.16...deep_causality_rand-v0.2.0) - 2026-07-08

### Added

- *(deep_causality_rand)* Sobol sequence + inverse-CDF transforms for QMC
- *(deep_causality_rand)* Generalize the distribution surface from Float to Real
- *(deep_causality_num)* removed chacha20 csprng to remove unsafe code.

### Fixed

- *(deep_causality_rand)* Format and linting
- *(deep_causality_rand)* Fixed miri test config
- *(deep_causality_rand)* Fixed miri test config
- *(deep_causality_rand)* Fixed miri test config

### Other

- Fixed dependencies version in various crate to fix CI auto release.
- *(num)* split deep_causality_num into num-core + algebra + complex + dual
- *(bazel)* register all missing test suites; add Dual Default; move iso test utils to src/utils_tests
- Generated new SBOM for all crates.
- Updated README file across multiple crates to meet project standard.

## [0.1.16](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.15...deep_causality_rand-v0.1.16) - 2026-06-09

### Added

- *(deep_causality_rand)* hoist float sampling into generic kernels; add Float106 distributions
- *(deep_causality_algorithms)* BRCD MEC engine — exact AMO enumeration over MixedGraph

### Other

- enforce repo-wide `unsafe_code = "forbid"`; remove avoidable unsafe

## [0.1.15](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.14...deep_causality_rand-v0.1.15) - 2026-05-26

### Other

- updated the following local packages: deep_causality_num

## [0.1.14](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.13...deep_causality_rand-v0.1.14) - 2026-03-12

### Other

- Updated all SBOMS to reflect lates depdency versions.

## [0.1.13](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.12...deep_causality_rand-v0.1.13) - 2026-02-10

### Added

- *(deep_causality_rand)* Added default to ChaCha20Rng impl.

### Fixed

- *(deep_causality_rand)* Fixed  Buffer Allocation
- *(deep_causality_rand)* Fixed zerioization in ChaCha20Poly1305 CSPRNG
- *(deep_causality_rand)* Added Osrandomrn in scope

### Other

- Merge remote-tracking branch 'origin/main'
- regenerated SBMO for rand crate. Code formatting.
- Added hardware secure CSPRNG to rand crate

## [0.1.12](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.11...deep_causality_rand-v0.1.12) - 2026-02-09

### Other

- Updated cargo dependencies.

## [0.1.11](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.10...deep_causality_rand-v0.1.11) - 2026-01-22

### Other

- *(deep_causality_rand)* Fixed Thread-Local RNG bug. Updated docstring.

## [0.1.10](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.9...deep_causality_rand-v0.1.10) - 2026-01-09

### Other

- updated project wide SBOM files.
- updated project wide copyright note.

## [0.1.9](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.8...deep_causality_rand-v0.1.9) - 2025-12-31

### Other

- Updated SBOMs to trigger release.

## [0.1.8](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_rand-v0.1.7...deep_causality_rand-v0.1.8) - 2025-12-31

### Other

- updated the following local packages: deep_causality_num

## [0.1.7](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.6...deep_causality_rand-v0.1.7) - 2025-12-18

### Fixed

- *(deep_causality_rand)* Fixed a number of bugs. Updated tests for verification.

## [0.1.6](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_rand-v0.1.5...deep_causality_rand-v0.1.6) - 2025-12-03

### Added

- *(deep_causality_sparse)* Fixing auto-release

### Other

- Regenerated SBOM.
- Merge branch 'deepcausality-rs:main' into main
- Restored manually generated SBOM to restore Dependency and licence scan.

## [0.1.5](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.4...deep_causality_rand-v0.1.5) - 2025-11-23

### Removed

- removed all manually generated SBOM files

## [0.1.4](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.3...deep_causality_rand-v0.1.4) - 2025-11-05

### Other

- Updated SBOM for all crates.

## [0.1.3](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.2...deep_causality_rand-v0.1.3) - 2025-09-25

### Other

- Updated SBOM for all crates.
- Updated SBOM for all crates.

## [0.1.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.1...deep_causality_rand-v0.1.2) - 2025-09-22

### Fixed

- *(deep_causality)* Removed last internal macros and removed dependency on deep_causality_macro crate.

### Other

- Updated SBOM script to generate hash signature together with the SBOM.

## [0.1.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_rand-v0.1.0...deep_causality_rand-v0.1.1) - 2025-09-21

### Other

- Updated Cargo configuration and feature propagation across the entire repo.
