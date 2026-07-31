# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.3](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.9.2...ultragraph-v0.9.3) - 2026-07-14

### Fixed

- *(deep_causality_physics)* Fixing 10MB max upload limit on crates.io

## [0.9.2](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.9.1...ultragraph-v0.9.2) - 2026-07-08

### Other

- *(num)* split deep_causality_num into num-core + algebra + complex + dual
- Generated new SBOM for all crates.
- *(papers)* Reorganized publication by moving each paper into the crate where it is actually implemented.
- Updated README file across multiple crates to meet project standard.

## [0.9.1](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.9.0...ultragraph-v0.9.1) - 2026-06-09

### Other

- enforce repo-wide `unsafe_code = "forbid"`; remove avoidable unsafe

## [0.9.0](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.16...ultragraph-v0.9.0) - 2026-05-26

### Added

- *(ultragraph)* add biconnectivity decomposition ([#581](https://github.com/deepcausality-rs/deep_causality/pull/581))

### Fixed

- *(ultragraph)* preserve multi-edge multiplicity in undirected biconnectivity view

### Other

- *(ultragraph)* biconnectivity decomposition ([#581](https://github.com/deepcausality-rs/deep_causality/pull/581))

## [0.8.16](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.15...ultragraph-v0.8.16) - 2026-05-03

### Other

- Applied minor lints.

## [0.8.15](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.14...ultragraph-v0.8.15) - 2026-03-12

### Other

- Updated all SBOMS to reflect lates depdency versions.

## [0.8.14](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.13...ultragraph-v0.8.14) - 2026-02-09

### Other

- updated all cargo dependencies to the latest version.
- *(ultragraph)* Fixed typo in README code example
- Fixed typo
- *(ultragraph)* Added example correctly to Cargo.toml
- Fixed some lints.

## [0.8.13](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.12...ultragraph-v0.8.13) - 2026-01-09

### Other

- updated project wide SBOM files.
- updated project wide copyright note.

## [0.8.12](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.11...ultragraph-v0.8.12) - 2025-12-12

### Other

- Updated criterion across the repo.

## [0.8.11](https://github.com/marvin-hansen/deep_causality/compare/ultragraph-v0.8.10...ultragraph-v0.8.11) - 2025-12-03

### Other

- Updated dev dependencies across the repo.
- Merge branch 'deepcausality-rs:main' into main
- Restored manually generated SBOM to restore Dependency and licence scan.

## [0.8.10](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.9...ultragraph-v0.8.10) - 2025-11-23

### Removed

- removed all manually generated SBOM files

## [0.8.9](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.8...ultragraph-v0.8.9) - 2025-11-05

### Other

- Updated SBOM for all crates.

## [0.8.8](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.7...ultragraph-v0.8.8) - 2025-09-25

### Other

- Updated SBOM for all crates.
- Updated SBOM for all crates.

## [0.8.7](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.6...ultragraph-v0.8.7) - 2025-09-22

### Fixed

- *(deep_causality)* Removed last internal macros and removed dependency on deep_causality_macro crate.

### Other

- Updated SBOM script to generate hash signature together with the SBOM.

## [0.8.6](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.5...ultragraph-v0.8.6) - 2025-09-21

### Other

- Updated Cargo configuration and feature propagation across the entire repo.
- Lots of lints and formats. Updated MSRV to 1.89 and edition 2024 across the entire repo.
- *(deep_causality_rand)* Increased test coverage.

## [0.8.4](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.3...ultragraph-v0.8.4) - 2025-09-08

### Added

- *(ultragraph)* removed unused dependencies. ultragraph has no zero build dependencies.
- *(deep_causality_macros)* removed overly complex constructure macro.

## [0.8.3](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.2...ultragraph-v0.8.3) - 2025-08-27

### Added

- *(ultragraph)* Added debug impl to UltraGraph

### Fixed

- *(ultragraph)* fixed failing test.

### Other

- *(deep_causality)* Improved test coverage

## [0.8.2](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.8.1...ultragraph-v0.8.2) - 2025-08-08

### Other

- Updated copyright in Cargo.toml fils
- Updated dependencies in UltraGraph and for Bazel.
- Updated UltraGraph README.md
- Improved docstring
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.1](https://github.com/marvin-hansen/deep_causality/compare/ultragraph-v0.8.0...ultragraph-v0.8.1) - 2025-07-10

### Other

- Improved perf of deduplication in brandes_bfs_and_path_counting
- Improved test coverage
- Fixed breaking API by restring previous public re-export.
- Added test coverage for betweenness_centrality algo.
- Implemented Brandes' algorithm
- Refactored ultragraph's trait system and algo implementations for better maintainability.
- Updated README.md
- Formatting and linting.
- Improved test coverage.
- Added Tarjan's algorithm to UltraGraph.
- Improved test coverage for Dijkstra's algorithm. Improved docstring.
- Removed problematic check in Dijkstra's algorithm
- Added Dijkstra's algorithm to UltraGraph.
- Fixed a memory leak in the ultragraph benchmark.

## [0.5.6](https://github.com/marvin-hansen/deep_causality/compare/ultragraph-v0.5.5...ultragraph-v0.5.6) - 2025-06-19

### Other

- Merge pull request #201 from deepcausality-rs/release-plz-2025-04-03T05-42-30Z
- Bump criterion from 0.5 to 0.6.0

## [0.5.5](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.5.4...ultragraph-v0.5.5) - 2025-05-16

### Other

- Fixed tests, benchmarks, and fixed some lints
- Bump rand from 0.8.5 to 0.9.0
- Bump petgraph from 0.6.6 to 0.7.0

## [0.5.4](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.5.3...ultragraph-v0.5.4) - 2024-11-24

### Other

- Bumped up minimum rust version to 1.80.

## [0.5.3](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.5.2...ultragraph-v0.5.3) - 2024-11-21

### Other

- update Cargo.lock dependencies

## [0.5.2](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.5.1...ultragraph-v0.5.2) - 2024-01-14

### Other
- Updated dependencies in Ultragraph.
- Updated dependencies in ultragraph crate.

## [0.5.1](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.5.0...ultragraph-v0.5.1) - 2023-09-06

### Other
- Fixed various linting issues.

## [0.5.0](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.4.6...ultragraph-v0.5.0) - 2023-08-30

### Other
- Switched to shorter version numbers in Cargo.toml
- Fixed linter issue
- Formatted entire code base with rustfmt.
- Separate ultragraph type implementation imn multiple files.
- Added convince constructor to error
- Fixed broke test  for node remove error.
- Added missing none checks to graph_root_tests.rs
- Fixed fallibility in shortest path.
- Separate ultragraph tests into multiple files.
- Renamed example code files to prevent output file name collision.
- Updated copyright in all source and bash script files.
- Updated copyright in all licence files.

## [0.4.6](https://github.com/deepcausality-rs/deep_causality/compare/ultragraph-v0.4.5...ultragraph-v0.4.6) - 2023-08-17

### Other

- Added remaining tests to ultragraph
- updated tests in ultragraph.
- Reduced benchmark graph size to decrease CI runtime.
