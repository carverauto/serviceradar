# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.7.0...deep_causality_topology-v0.7.1) - 2026-07-14

### Fixed

- *(deep_causality_physics)* Fixing 10MB max upload limit on crates.io

### Other

- Improved test coverage.

## [0.7.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.6.1...deep_causality_topology-v0.7.0) - 2026-07-08

### Added

- *(deep_causality_topology)* opt-in deterministic cut-cell iteration order
- *(deep_causality_physics)* wire aperture-resolved immersed no-slip into the DEC solver
- *(deep_causality_physics)* one-sided wall-normal friction diagnostic (Kirkpatrick true Δh)
- *(deep_causality_topology)* aperture-resolved cut-face no-slip — geometry + weighted KKT projector
- *(deep_causality_topology)* net-flux open-boundary Leray projection
- *(cfd)* Small-cut-cell stabilization — CFD Stage 4 B1–B3 (cell-merging; inherent stability finding)
- *(cfd)* Cut-cell cylinder wake harness — CFD Stage 4 Group D
- feat(deep_causality_topology):
- *(cfd)* Cut cells flow through the DEC NS solver via a registry-aware Hodge star — Stage 4 B5
- *(deep_causality_topology)* Cut-aware Hodge star — CFD Stage 4 Group B foundation
- *(deep_causality_topology)* Cut-cell geometry substrate — CFD Stage 4 Group A (add-cut-cells-and-immersed-boundaries)
- *(deep_causality_topology)* Add graded (variable-spacing) metric constructors — CFD R1
- *(deep_causality_physics)* Add the wall-bounded DEC Navier-Stokes
- *(deep_causality_topology)* Add wall substrate - DCT transforms,
- *(deep_causality_fft)* Add FFT crate, deep_causality_par, and the spectral Poisson solve (closes add-fft)
- *(deep_causality_topology)* Add DEC exterior algebra, de Rham transfer,

### Fixed

- *(haft)* [**breaking**] align law docs with proved theory; make effect-system reference impl lawful
- *(deep_causality_topology)* Fixed bazel test config
- *(deep_causality_topology)* Diagnosis (2026-06-12, task 1.3 — budget probe on the 32³ Re-1600 trajectory): hypothesis (1) confirmed. The convective power ⟨u, −i_u(du)⟩_M is exactly zero on the smooth single-mode initial state (−9e-16), turns positive as the spectrum fills (+0.59 at t* 3.1, +28 at 7.9), and overwhelms the viscous sink (always properly negative) at t* ≈ 8.5 — energy growth follows.

### Other

- *(num)* split deep_causality_num into num-core + algebra + complex + dual
- *(bazel)* register all missing test suites; add Dual Default; move iso test utils to src/utils_tests
- *(deep_causality_topology)* close reachable coverage gaps; document defensive remainder
- raise test coverage across 8 crates.
- Generated new SBOM for all crates.
- *(dec-solver)* warm-start the λ (cut-face multiplier) block in the weighted projection
- *(dec-solver)* projection CG warm-start + cycle-mean cylinder drag
- *(openspec)* Drop fix-graded-convective-consistency — premise superseded by findings
- *(deep_causality_topology)* Verify operator convergence on graded metrics — CFD R1 (B1)
- *(deep_causality_topology)* Memoize the diagonal Hodge star to take
- *(deep_causality_topology)* Add compiled DEC stencil tables and the
- *(deep_causality_num)* Add table-based fast path for Float106::sin_cos
- *(deep_causality_topology)* Add DEC solver benchmark, eliminate
- *(deep_causality_topology)* Memoize boundary matrices and preserve

## [0.6.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.6.0...deep_causality_topology-v0.6.1) - 2026-06-09

### Added

- *(deep_causality_num)* split Real from RealField; blanket the float tower
- *(deep_causality_num)* split Real out of RealField
- *(deep_causality_topology)* add MixedGraph — typed-endpoint mixed graph (CPDAG/MAG/PAG)
- *(tensor)* add sample mean/covariance; topology covariance delegates to it

### Other

- *(deep_causality)* fix rustdoc intra-doc link warnings
- *(sparse,topology)* lift cg_solve into deep_causality_sparse as public API
- *(topology)* remove source-scanning grep-tests
- enforce repo-wide `unsafe_code = "forbid"`; remove avoidable unsafe

## [0.6.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.5.1...deep_causality_topology-v0.6.0) - 2026-05-26

### Added

- *(deep_causality_topology)* add PointCloud::triangulate_delaunay
- *(topology)* surface triangulate degeneracy via discriminating errors
- *(deep_causality_topology)* TopologicalInvariants extractor (B1a)
- *(deep_causality_topology)* hodge_decompose algorithm + matrix-free CG (H2)
- *(deep_causality_topology)* HodgeDecomposition carrier type + error variant (H1)
- *(deep_causality_topology)* Regge action gradient + Metropolis-Hastings (R6)
- *(deep_causality_topology)* Lorentzian signature marker + Wick-rotated action (R5)
- *(deep_causality_topology)* Manifold generic widening over ChainComplex (R4.5)
- *(deep_causality_topology)* PerEdge cubical Hodge star (R4.4)
- *(deep_causality_topology)* cubical HasHodgeStar impl, UnitEdge + Uniform + PerAxis tiers (R4.3)
- *(deep_causality_topology)* simplicial HasHodgeStar impl + manifold trait routing (R4.2)
- *(deep_causality_topology)* add HasHodgeStar<R> capability trait (R4.1)
- *(deep_causality_topology)* cubical Regge core R3 — deficit + action
- *(deep_causality_topology)* cubical Regge core R2 — hinges + dihedrals
- *(deep_causality_topology)* cubical Regge core R1 — cell volumes
- *(doc)* Consolidated all m examples in the dedicated example folder.
- *(deep_causality_topology)* Implemented specs for generalizing topology crate over RealField
- *(deep_causality_num)* add Tier 1 isomorphism marker subtraits (iso-traits Stage A)
- *(topology)* Increased test coverage.
- *(topology)* Completed #487.
- *(topology)* LatticeComplex + cubical aliases + Neighborhood strategies (Stage C)
- *(topology)* genericize Manifold over ChainComplex (Stage B)

### Fixed

- *(deep_causality_topology)* three Regge-geometry follow-ups
- *(deep_causality_topology)* three Regge-geometry follow-ups
- *(point_cloud)* cap triangulate top-grade at ambient dimension
- *(deep_causality_topology)* tighten covariance domain; loosen Manifold constructor bounds

### Other

- Rolled back accidental edit of change log.
- *(deep_causality_topology)* tighten cross-backend Hodge test on Delaunay
- *(openspec)* release prep for harden-simplicial-hodge-degeneracy-detection
- *(deep_causality_topology)* lazy Hodge ⋆ population via OnceLock
- *(deep_causality_topology)* tighten two fixtures to satisfy
- *(deep_causality_topology)* regression suite for triangulate degeneracy rejection
- Added a new specification for add-pointcloud-delaunay-triangulation
- *(deep_causality_topology)* Hodge decomposition property tests (H3)
- *(deep_causality_topology)* single-edge Regge gradient for Metropolis hot path
- *(deep_causality_topology)* route Cubical Regge signature truth through deep_causality_metric (R5.8)
- *(deep_causality_topology)* improved test coverage.
- *(deep_causality_topology)* cubical Regge core §5 — API + module doc
- *(deep_causality_topology)* cubical Regge core §1 scaffolding
- *(deep_causality_topology)* convert LatticeComplex coboundary cache to OnceLock
- *(topology)* R: RealField GAT skeleton (compile-broken)
- Added new specification for generalizing various grades over real field to enable precision as a parameter.
- *(topology)* introduce ChainComplex trait, drop _cpu suffix

## [0.5.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.5.0...deep_causality_topology-v0.5.1) - 2026-03-12

### Other

- Updated all SBOMS to reflect lates depdency versions.

## [0.5.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.4.0...deep_causality_topology-v0.5.0) - 2026-02-09

### Other

- updated all cargo dependencies to the latest version.
- Fixed more lints.
- *(deep_causality_topology)* Added Stry_from_phase to gauge link.
- *(deep_causality_topology)* Added Source of the Field to the Lattice Gauge Field.
- *(deep_causality_num)* Added is_nan, is_infinite, and is_finite to Float106 type

## [0.4.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.3.0...deep_causality_topology-v0.4.0) - 2026-01-22

### Added

- *(deep_causality_topology)* Added SE3 Gauge Group of rigid body motions. .
- *(deep_causality_tensor)* Finalized MLX removal.
- *(deep_causality_tensor)* Removed MLX backed.
- *(deep_causality_topology)* Removed MLX backed.
- *(deep_causality_multivector)* Removed MLX backed.
- *(deep_causality_topology)* Updated and revised implementation of Lattice Gauge Field.
- *(deep_causality_topology)* Updated and revised implementation of Lattice Gauge Field.
- *(deep_causality_topology)* Initial implementation of Lattice Gauge Field.

### Fixed

- *(deep_causality_topology)* Applied lints and fixes.

### Other

- *(deep_causality_topology)* Renamed Guage Groups to their definition names.
- *(deep_causality_num)* Renamed DoubleFloat to Float106 for consistency with existing float types.
- *(deep_causality_topology)* Fixed  numerous bugs.
- remoced unneccessary trait bounds.
- Updated SBOM of and applied docstring fixes.
- Updated SBOM of recently changed crates.
- Updated Bazel config
- Applied lints and fixes across crates.
- *(deep_causality_topology)* Applied lints and fixes.
- *(deep_causality_topology)* Refeactoring to allow for genric fields and ComplexFiels in GaugeField and LatticeGauge Field
- *(deep_causality_topology)* Initial verification of the Lattice Gauge Field.
- *(deep_causality_topology)* Applied lints and fixes.
- *(deep_causality_topology)* Applied lints and fixes.
- *(deep_causality_topology)* Applied lints and fixes.
- *(deep_causality_topology)* Increased test coverage, applied lints and fixes.
- *(deep_causality_topology)* Increased test coverage, applied lints and fixes.
- *(deep_causality_topology)* Increasded test coverage, applied lints and fixes.
- *(deep_causality_topology)* Increasded test coverage, applied lints and fixes.
- *(deep_causality_topology)* Increasded test coverage.
- Merge branch 'deepcausality-rs:main' into main
- *(deep_causality_topology)* Updated SBOM
- *(deep_causality_topology)* Added exaple for Lattice Gauge Field impl.
- *(deep_causality_topology)* Documented  and revised Lattice Gauge Field impl.
- *(deep_causality_topology)* Reviewed initial implementation of Lattice Gauge Field.
- *(deep_causality_topology)* Tested initial implementation of Lattice Gauge Field.

## [0.3.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.2.5...deep_causality_topology-v0.3.0) - 2026-01-09

### Added

- *(deep_causality_topology)* Fixed a number of lints
- *(deep_causality_topology)* Fixed MLX gated impl to use new manifold generics.
- *(deep_causality_physics)* Expanded gauge field usage for calculations in all gauge theories. Made ADM ops generic over Field. Updated examples. Added docs.
- *(deep_causality_physics)* Completed integration of new DoubleFloat Type.
- *(deep_causality_topology)* Fixed some tests.
- *(deep_causality_topology)* Made all topology types and extensions generic to work with new DoubleFloat Type.
- *(deep_causality_physics)* Updated and improved Gauge based GR theory.
- *(deep_causality_physics)* Implemented Gauge GR theory.
- *(deep_causality_physics)* Immproved Electroweak implementation.
- *(deep_causality_physics)* Immproved QED implementation.
- *(deep_causality_topology)* Restructed hkt modules for better code organization.
- *(deep_causality_physics)* Implemented kerneles required for implementing subsequent gauge theories.
- *(deep_causality_topology)* Finalized and reviewed Gauge Field and related types.
- *(deep_causality_topology)* Implemented HKT traits for Gauge Field and related types.
- *(deep_causality_topology)* Completed implementation. Added tests.
- *(deep_causality_topology)* Initial implementation of Gauge Field.
- *(deep_causality_topology)* Removed unused dependency.
- *(deep_causality_multivector)* Migrated to dedicted pure HKT trait.
- *(deep_causality_topology)* Completed transition to GAT based HKT.

### Other

- *(deep_causality_topology)* Fixed some tests.
- *(deep_causality_physics)* increased test coverage.
- *(deep_causality_topology)* increased test coverage.
- Updated Bazel build and test config.
- repo wide lints and fixes
- repo wide lints and formatting.
- *(deep_causality_num)* increased test coverage.
- updated project wide SBOM files.
- updated project wide copyright note.
- Addes specs for gauge fiels. Prepared implementation.
- Migrated to dedicted pure HKT trait.

## [0.2.5](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.2.4...deep_causality_topology-v0.2.5) - 2025-12-31

### Other

- updated the following local packages: deep_causality_multivector

## [0.2.4](https://github.com/marvin-hansen/deep_causality/compare/deep_causality_topology-v0.2.3...deep_causality_topology-v0.2.4) - 2025-12-31

### Added

- *(deep_causality_multivector)* separated MLX code into dedicted files for better maintainabiliy.
- *(deep_causality_multivector)* Added algebraic trait impl for MultiField.
- *(deep_causality_topology)* Updated benchmarks.
- *(deep_causality_topology)* Added new benchmark for multi backend support.
- *(deep_causality_topology)* Added new lattice types and initial multi backend supporte.
- *(deep_causality_tensor)* Fixed tests for new backend agnostic CPU impl.
- *(deep_causality_topology)* Imlemented initial MLX acceleration. Closes #432
- *(deep_causality_metric)* Integrated new metric crate across the repo.

### Fixed

- *(deep_causality_topology)* Minor fixes and lints.

### Other

- Lots of lints, formatting, and minor fixes.
- Lots of lints, formatting, and minor fixes.
- Minor lints.

## [0.2.3](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.2.2...deep_causality_topology-v0.2.3) - 2025-12-18

### Fixed

- *(deep_causality_topology)* Fixed a number of topology related bugs. Updated tests for verification.

## [0.2.2](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.2.1...deep_causality_topology-v0.2.2) - 2025-12-14

### Other

- *(deep_causality_topology)* Increased test coverage.

## [0.2.1](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.2.0...deep_causality_topology-v0.2.1) - 2025-12-12

### Other

- updated the following local packages: deep_causality_multivector

## [0.2.0](https://github.com/deepcausality-rs/deep_causality/compare/deep_causality_topology-v0.1.0...deep_causality_topology-v0.2.0) - 2025-12-12

### Added

- *(deep_causality_physics)* Added generalized_master_equation_kernel to dynamic module.
- *(deep_causality_topology)* Added Regge Calculus Curvature and tests. Improved error handling by updating the  TopologyError.  Added SimplicialComplexBuilder for constructing correct SimplicialComplex.
- *(deep_causality_topology)* Removed non-std config. Updated Bazel config.

### Fixed

- *(deep_causality_physics)* Fixed a subliminal bug around Laplacian and  Boundary Operator Indexing.

### Other

- Added a lot more examples across physics and medicine.
- Added two new physics exmples.
- *(deep_causality_topology)* Improved test coverage.
- *(deep_causality_topology)* Improved test coverage.
- *(deep_causality_topology)* Improved test coverage.
- *(deep_causality_topology)* Improved test coverage.

## [0.1.0](https://github.com/marvin-hansen/deep_causality/releases/tag/deep_causality_topology-v0.1.0) - 2025-12-03

### Added

- *(deep_causality_multivector)* Ported CausalMultiVector to use Field instead of the broader Num trait to ensure correct math.
- *(deep_causality_topology)* Added examples and README.md
- *(deep_causality_topology)* refactored for better code organization.
- *(deep_causality_topology)* refactored for performance improvements and better code organization.
- *(deep_causality_topology)* Added test utils
- *(deep_causality_topology)* Improved Manifold impl.
- *(deep_causality_topology)* Added Graph topology with HKT types.
- *(deep_causality_topology)* Added Hypergraph topology with HKT types.
- *(deep_causality_topology)* Added HKT and functional trait impl for Manifold topology.
- *(deep_causality_topology)* Added Manifold topology.
- *(deep_causality_topology)* Added PointCloud topology. Added TopologyError. Added Topology Trait hierarchy.
- *(deep_causality_topology)* Initial implementation of topology data structures.

### Other

- Regenerated SBOM.
- *(deep_causality_topology)* Fixed discrete differential geometry examples.
- *(deep_causality_topology)* Fixed discrete differential geometry on simplicial complexes. Fixed Cup product on topology.
- *(deep_causality_topology)* Moved to core traits instead of std for better protability.
- *(deep_causality_topology)* Added examples and debugging discrete differential geometry.
- *(deep_causality_topology)* Added discrete differential geometry on simplicial complexes:Added new tests.
- *(deep_causality_topology)* implemented algebraic structure for Chain<T> in deep_causality_topology. Added new tests.
- *(deep_causality_topology)* Added SBOM.
- *(deep_causality_topology)* Increased test coverage.
- *(deep_causality_topology)* Added test coverage.
