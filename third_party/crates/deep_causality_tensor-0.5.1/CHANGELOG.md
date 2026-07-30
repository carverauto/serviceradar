# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.5.0...deep_causality_tensor-v0.5.1) - 2026-07-14

### Added

- *(deep_causality_quantum)* the operator/channel layer on CausalTensor<Complex<R>> (Phase 2)

### Fixed

- *(deep_causality)* code formatting
- *(deep_causality_quantum)* Added NaN/overflow/bounds check to Haruna gates
- *(deep_causality_quantum)* Added NaN/overflow/bounds check to Haruna gates
- *(deep_causality)* Minor fix
- *(deep_causality_physics)* Fixing 10MB max upload limit on crates.io

### Other

- *(deep_causality_tensor)* Improved testing
- Improved test coverage.

## [0.5.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.4.4...deep_causality_tensor-v0.5.0) - 2026-07-08

### Added

- *(deep_causality_tensor)* complete the tensor-train operator algebra
- *(deep_causality_tensor)* randomize-then-orthogonalize TT round + precision-generic RNG
- *(deep_causality_tensor)* adaptive randomized TT-rounding
- *(deep_causality_tensor)* tensor-network benchmarks (group 7) + spec sync
- *(deep_causality_tensor)* complex Hermitian eigensolver — solve::eigen at Complex
- *(deep_causality_tensor)* complex TT solvers — AMEn linear, ALS fit, TDVP
- *(deep_causality_tensor)* complex TT-cross (ConjugateScalar)
- *(deep_causality_tensor)* complex matrix-product operators (ConjugateScalar)
- *(deep_causality_tensor)* complex tensor-train state layer (ConjugateScalar)
- *(deep_causality_num,deep_causality_tensor)* complex-capable SVD/QR kernels via ConjugateScalar
- *(deep_causality_tensor)* tensor-network Stage 3 — two-site TDVP2 time step
- *(deep_causality_tensor)* tensor-network Stage 3 — DMRG3S eigensolver
- *(deep_causality_tensor)* tensor-network Stage 2c — ALS solve engine + integrate
- *(deep_causality_tensor)* tensor-network Stage 2b — TT-cross + apply_nonlinear
- *(deep_causality_tensor)* tensor-network Stage 2a — CausalTensorTrainOperator (MPO)
- *(deep_causality_tensor)* tensor-network Stage 1 — CausalTensorTrain (MPS) state
- *(deep_causality_tensor)* tensor-network Stage 0 — truncated SVD, QR, Truncation

### Other

- *(num)* split deep_causality_num into num-core + algebra + complex + dual
- *(physics,tensor,file)* skip Miri-incompatible tests
- *(deep_causality_tensor)* fused Hadamard-round, inner buffer reuse, crossover study
- *(deep_causality_tensor)* Updated README.md
- *(deep_causality_tensor)* tensor-network — document Stage-4 scalar generality
- *(deep_causality_tensor)* tensor-network Stage 4 — Dual<f64> forward-mode AD
- *(deep_causality_tensor)* tensor-network — AMEn linear solve + algorithm citations
- *(openspec)* Added specs for tensor network.
- *(deep_causality_tensor)* Improve test coverage
- Generated new SBOM for all crates.
- Updated README file across multiple crates to meet project standard.

## [0.4.4](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.4.3...deep_causality_tensor-v0.4.4) - 2026-06-09

### Added

- *(deep_causality_tensor)* add logsumexp, gaussian log-density, conditional variance
- *(tensor)* add sample mean/covariance; topology covariance delegates to it

### Fixed

- *(deep_causality_discovery,deep_causality_tensor)* make f64→T casts honest; sync docs to generic T

### Other

- *(num,tensor)* make CausalTensorMathExt generic over RealField
- enforce repo-wide `unsafe_code = "forbid"`; remove avoidable unsafe

## [0.4.3](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.4.2...deep_causality_tensor-v0.4.3) - 2026-05-26

### Added

- *(doc)* Consolidated all m examples in the dedicated example folder.

### Other

- *(miri)* exclude doctests from Miri runs
- skip stat/float doctests under Miri

## [0.4.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.4.1...deep_causality_tensor-v0.4.2) - 2026-03-12

### Other

- Updated all SBOMS to reflect lates depdency versions.

## [0.4.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.4.0...deep_causality_tensor-v0.4.1) - 2026-02-09

### Other

- updated all cargo dependencies to the latest version.

## [0.4.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.3.0...deep_causality_tensor-v0.4.0) - 2026-01-22

### Added

- *(deep_causality_tensor)* Updated tests.
- *(deep_causality_tensor)* Finalized MLX removal.
- *(deep_causality_tensor)* Removed MLX backed.

### Other

- *(deep_causality_tensor)* Fixed  numerous bugs.
- Updated SBOM of and applied docstring fixes.
- Updated SBOM of recently changed crates.

## [0.3.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.2.2...deep_causality_tensor-v0.3.0) - 2026-01-09

### Added

- *(deep_causality_tensor)* Disabled strict Witness pattern and with it proper GAT bounded HKT due to issue in trait solver.
- *(deep_causality_tensor)* Identified root cause of failing GAT normalization errors a compiler bugs. Documented the issue for now.
- *(deep_causality_tensor)* Completed transition to GAT based HKT.
- *(deep_causality_sparse)* Finalized HKT extension to use new GAT bounded HKT.
- *(deep_causality_tensor)* Finalized HKT extension to use new GAT bounded HKT.
- *(deep_causality_tensor)* Upated HKT extension to use new GAT bounded HKT.

### Other

- updated project wide SBOM files.
- updated project wide copyright note.
- Removed unused feature flag.

## [0.2.2](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_tensor-v0.2.1...deep_causality_tensor-v0.2.2) - 2025-12-31

### Added

- *(deep_causality_tensor)* Code formatting.
- *(deep_causality_tensor)* Improved error handling and propagation.
- *(deep_causality_tensor)* Applied multiple lints, fixes, and code improvements.
- *(deep_causality_tensor)* Applied multiple lints, fixes, and code improvements.
- *(deep_causality_tensor)* Applied multiple lints, fixes, and code improvements.
- *(deep_causality_multivector)* Increased test coverage.
- *(deep_causality_multivector)* Increased test coverage.
- *(deep_causality_tensor)* Increased test coverage.
- *(deep_causality_tensor)* Updated benchmarks
- *(deep_causality_tensor)* Added black_box to benchmarks
- *(deep_causality_topology)* Added new benchmark for multi backend support.
- *(deep_causality_tensor)* Impvroved code organization and maintainability of the crate.
- *(deep_causality_tensor)* Added new ein_sum benchmark and updated README.md.
- *(deep_causality_tensor)* Fixed dowstream tests
- *(deep_causality_tensor)* Updated new benchmark and updated README.md.
- *(deep_causality_tensor)* Added new benchmark to compare CPU vs MLX execution.
- *(deep_causality_tensor)* Added MLX backend.
- *(deep_causality_tensor)* Finalized new backend agnostic CPU impl.
- *(deep_causality_tensor)* Fixed tests for new backend agnostic CPU impl.
- *(deep_causality_tensor)* Fixed benchmarks and code examples.
- *(deep_causality_tensor)* Completed backed agnostic acceletation for CPU.
- *(deep_causality_tensor)* Implemented backed agnostic acceletation for CPU.
- *(deep_causality_tensor)* Introduced backend tensor as stub for backend specific implementations of tensor ops.
- *(deep_causality_tensor)* Added initial MLX backend.
- *(deep_causality_tensor)* Added initial CPU backend.
- *(deep_causality_tensor)* Removed initial MLX acceleration as preparation for backend impl.
- *(deep_causality_physics)* Implemented MLX acceleration to close issue #428

### Fixed

- *(deep_causality_topology)* Minor fixes and lints.

### Other

- Minor lint
- Lots of lints, formatting, and minor fixes.

## [0.2.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.2.0...deep_causality_tensor-v0.2.1) - 2025-12-18

### Other

- updated the following local packages: deep_causality_num

## [0.2.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.1.10...deep_causality_tensor-v0.2.0) - 2025-12-12

### Added

- *(deep_causality_tensor)* Added inverse, cholesky_decomposition and solve_least_squares_cholsky operations.

### Fixed

- fixed a number of Bazel config files.
- *(deep_causality_tensor)* Lints and code improvements.
- *(deep_causality_tensor)* Minor lints and code improvements.
- *(deep_causality_tensor)* Minot lints and code improvements.
- *(deep_causality_tensor)* Fixed permute_axes impl, fixed inverse_impl for singular matrix case, fixed solve_least_squares_cholsky_impl and fixed cholesky_decomposition_impl.

### Other

- Updated criterion across the repo.
- *(deep_causality_tensor)* Added  matmul as wrapper for ein_sum.
- *(deep_causality_tensor)* Added identity from Ring trait and matmul as wrapper for ein_sum.
- *(deep_causality_multivector)* Improved test coverage.
- *(deep_causality_tensor)* Improved test coverage.

## [0.1.10](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_tensor-v0.1.9...deep_causality_tensor-v0.1.10) - 2025-12-03

### Added

- *(deep_causality_sparse)* Fixing auto-release
- *(deep_causality_tensor)* Added full set of new algebraic trait system to CausalTensor.
- *(deep_causality_topology)* Initial implementation of topology data structures.

### Other

- Regenerated SBOM.
- Updated dev dependencies across the repo.
- *(deep_causality_topology)* Fixed discrete differential geometry examples.
- *(deep_causality_tensor)* Added implementation of BoundedAdjunction trait as type extension.
- *(deep_causality_haft)* Added BoundedAdjunction trait.
- Merge branch 'deepcausality-rs:main' into main
- Merge remote-tracking branch 'origin/main'
- Restored manually generated SBOM to restore Dependency and licence scan.

## [0.1.9](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.1.8...deep_causality_tensor-v0.1.9) - 2025-11-23

### Other

- Merge branch 'deepcausality-rs:main' into main

### Removed

- removed all manually generated SBOM files

## [0.1.8](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.1.7...deep_causality_tensor-v0.1.8) - 2025-11-23

### Added

- *(deep_causality_multivector)* Added General Relativistic Magnetohydrodynamics example
- *(deep_causality_tensor)* refactored public Tensor API as a trait.
- *(deep_causality_multivector)* Added BoundedComonad impl as type extension.
- *(deep_causality_tensor)* Implemented CoMonad for Causaltensor
- *(deep_causality_haft)* Introduced Default trait bound to MonadEffect types to simplify error case handling. Update downstream deps.
- *(deep_causality_tensor)* Reformatted ein_sum example.

### Other

- Merge branch 'deepcausality-rs:main' into main

## [0.1.7](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.1.6...deep_causality_tensor-v0.1.7) - 2025-11-05

### Added

- *(deep_causality_tensor)* Updated EinSumOp for better ergonomics.
- *(deep_causality_tensor)* Added From impl for value and reference to CausalTensor.
- *(deep_causality_tensor)* Refactored code organization and improved documentation of public API.
- *(deep_causality_tensor)* Refactored code organization
- Optimize N-dimensional tensor trace calculation
- *(deep_causality_tensor)* Updated and tested  implementation for Einstein Sum Convention.
- *(deep_causality_tensor)* Added initial implementation for Einstein Sum Convention.

### Other

- *(deep_causality_ast)* Improved test organization.
- *(deep_causality_tensor)* Improved test coverage and test organization.
- The mat_mul_2d function has been updated to use direct array access with
- *(deep_causality_tensor)* Improved test coverage of implementation for Einstein Sum Convention.
- linting and formatting.
- Optimize 2D tensor trace calculation
- Added new test cases to deep_causality_tensor/src/types/a
- *(deep_causality_tensor)* Added example code and updated Readme for  Einstein Sum.
- Updated Bazel config
- *(deep_causality_tensor)* Documented implementation for Einstein Sum Convention.
- Updated SBOM for all crates.

## [0.1.6](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.1.5...deep_causality_tensor-v0.1.6) - 2025-10-31

### Added

- *(deep_causality_tensor)* Moved TensorProduct implementation from an extension into the CausalTensor  type.
- *(deep_causality_tensor)* Added TensorProduct
- *(deep_causality)* Added MaybeUncertain and CausalTensor to PropagatingEffect. Updated tests.
- *(deep_causality_tensor)* Added Higher Kinded Type extension.

### Other

- *(deep_causality_tensor)* Added tests for TensorProduct
- *(deep_causality_tensor)* minor lints.
- *(deep_causality_tensor)* lints, fixes, and more tests.

## [0.1.5](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.1.4...deep_causality_tensor-v0.1.5) - 2025-10-02

### Added

- *(deep_causality_tensor)* Made CausalTensor no-copy / clone for broader usage with complex data ttpes i.e. Uncertain<T>.

## [0.1.4](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.1.3...deep_causality_tensor-v0.1.4) - 2025-09-25

### Other

- Updated SBOM for all crates.

## [0.1.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.1.1...deep_causality_tensor-v0.1.2) - 2025-09-22

### Fixed

- *(deep_causality)* Removed last internal macros and removed dependency on deep_causality_macro crate.

### Other

- Updated SBOM script to generate hash signature together with the SBOM.

## [0.1.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_tensor-v0.1.0...deep_causality_tensor-v0.1.1) - 2025-09-21

### Other

- Updated Cargo configuration and feature propagation across the entire repo.
