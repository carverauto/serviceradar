# DeepCausality Topology

**Topological Data Analysis (TDA) and Causal Geometry for Rust**

`deep_causality_topology` is a core crate of the `deep_causality` project, providing rigorous topological data
structures and algorithms for causal modeling, geometric deep learning, and complex systems analysis.

It bridges the gap between discrete data (graphs, point clouds) and continuous geometric structures (manifolds,
simplicial complexes), enabling advanced reasoning about the "shape" and connectivity of causal systems.

## Features

* **Comprehensive Topological Types**:
    * **Graph**: Efficient sparse-matrix based graphs for causal networks.
    * **Hypergraph**: Modeling higher-order relationships (hyperedges) between multiple nodes.
    * **SimplicialComplex**: Generalizing graphs to higher dimensions (triangles, tetrahedra) to capture voids and
      holes.
    * **LatticeComplex** (alias `CubicalComplex`): The cubical complex of a regular ℤᴰ grid, with optional periodic
      boundaries — the natural substrate for voxel grids, sensor arrays, and lattice gauge theory.
    * **CellComplex**: General CW-complex over arbitrary user-defined cells.
    * **Manifold**: Validated geometric structures, generic over any chain complex (`Manifold<K: ChainComplex, F>`).
    * **PointCloud**: Raw multi-dimensional data with Vietoris-Rips triangulation capabilities.
* **Unified Chain-Complex Abstraction**:
    * **`ChainComplex` trait**: A single static-dispatch trait (GAT-backed cell iteration, `Cow`-returning
      boundary/coboundary matrices) that `SimplicialComplex`, `LatticeComplex`, and `CellComplex` all implement.
      Downstream code (notably `Manifold`'s differential operators) reads ∂ and δ through the trait — zero-copy on
      the cache-rich simplicial path, lazy-memoized on the cubical path.
* **Topological Algorithms**:
    * **Vietoris-Rips Triangulation**: Convert point clouds into simplicial complexes at a given scale.
    * **Euler Characteristic**: Compute topological invariants ($\chi$) to classify shapes (e.g., healthy vs.
      pathological tissue).
    * **Boundary/Coboundary Operators**: Sparse matrix operators for algebraic topology computations.
    * **Betti Numbers**: Counting independent k-dimensional holes via the rank of ∂.
* **Algebraic Topology & Differential Geometry**:
    * **Chain Algebra**: Perform algebraic operations on chains (formal sums of simplices) and verify fundamental
      topological theorems like `∂∂=0`.
    * **Differential Operators**: Compute the exterior derivative (`d`), Hodge star (`⋆`), codifferential (`δ`), and
      Hodge-Laplacian (`Δ`) on discrete differential forms, on both the simplicial and cubical paths (the
      cubical star covers unit/uniform/per-axis/per-edge metric tiers, with the diagonal memoized per grade).
    * **Hodge Theory**: Detect topological features like holes and voids by finding harmonic forms (solutions to
      `Δω = 0`).
    * **Poisson Solves & Projections**: `Manifold::leray_project` (the divergence-free projection of a 1-form) and
      `hodge_decompose` route their grade-0 Poisson solves through a dispatch over three domain classes —
      fully periodic uniform boxes solve **directly via rFFT** (torus eigenbasis), wall-bounded/mixed uniform
      boxes solve **directly via DCT-I/DFT** (the boundary-corrected Δ₀ diagonalizes exactly in the cosine
      basis), and everything else (per-edge metrics, degenerate extents) falls back to **Jacobi-preconditioned
      CG** on the mass-weighted normal form. The direct paths are exact to rounding with no iteration budget.
    * **Constrained Leray Projection**: `Manifold::leray_project_constrained_opts` projects onto the
      *intersection* of the divergence-free subspace with an essential edge constraint set (`u|_E = 0`) — the
      M-orthogonal intersection projection that wall-bounded no-slip flows require (the plain projector and
      the coordinate constraint do not commute). Runs the masked-mass Poisson solve through Jacobi-PCG.
    * **Boundary-Corrected Hodge Star**: on open (wall) lattice axes, dual volumes clip by `2^{-b}` per
      boundary incidence (wall faces halve, edges quarter, 3D corners eighth); fully periodic lattices are
      bit-unchanged. The corrected star keeps `M_k·Δ_k` symmetric positive (semi)definite — the property the
      CG solves and the energy arguments rely on.
    * **Compiled DEC Stencils**: `DecStencilTables` compiles per-manifold flat gather tables for `d`, `δ`, and
      the convective chain (interior-product transport + cup-product wedge), folding incidence signs, Hodge
      diagonals, transport weights, and cup signs into the stored coefficients — the streaming evaluation
      strategy behind the DEC Navier–Stokes solver's hot loop, equivalence-gated against the generic
      operators in CI.
* **Neighborhood Strategies** (static-dispatch zero-sized strategy types):
    * **Chain-complex-generic**: `FaceAdjacent`, `CofaceAdjacent` — defined via ∂ and δ, work on any `ChainComplex`.
    * **Grid-only**: `VonNeumann`, `Moore`, `KRing<const K: usize>` — implemented for `LatticeComplex<D>` only.
      Useful for cellular-automata, sensor fusion, image filters, voxel-based diffusion.
    * Users add their own strategies (anisotropic LIDAR cones, half-space RF, etc.) by implementing
      `Neighborhood<K>` for a custom zero-sized type.
* **Higher-Kinded Types (HKT)**:
    * Implements `Functor`, `BoundedComonad` (Extract/Extend), and `BoundedAdjunction` (Unit/Counit) via
      `deep_causality_haft`.
    * Enables functional geometric patterns like "neighborhood extraction" (Comonad) and "geometric realization" (
      Adjunction).
    * Witnesses ship for each topology: `SimplicialManifoldWitness<C>` (full HKT stack), `GenericManifoldWitness<K>`
      (Functor over any chain complex), and `LatticeComplexWitness<D>` for the lattice-complex HKT plumbing.

## Core Concepts

| Type                                 | Description                                                                       | Mathematical Structure                      |
|:-------------------------------------|:----------------------------------------------------------------------------------|:--------------------------------------------|
| **PointCloud**                       | Set of points in $\mathbb{R}^n$ with metadata.                                    | Discrete Metric Space                       |
| **Graph**                            | Nodes and binary edges.                                                           | 1-Complex                                   |
| **Hypergraph**                       | Nodes and hyperedges (subsets of nodes).                                          | Hypergraph                                  |
| **SimplicialComplex**                | Collection of simplices closed under sub-simplices.                               | Simplicial Complex $K$                      |
| **LatticeComplex&lt;D&gt;**          | Canonical: cubical complex of a regular $\mathbb{Z}^D$ grid (optional periodic).  | Lattice-supported cubical complex           |
| **CubicalComplex&lt;D&gt;**          | Textbook alias for `LatticeComplex<D>` (see *Naming convention* below).           | (same)                                      |
| **LatticeCell&lt;D&gt; / CubicalCell** | Elementary k-cube (position + orientation bitmask).                             | Elementary cube $\prod_i [a_i, a_i {+} \epsilon_i]$ |
| **CellComplex**                      | Generalized simplicial complex over user-defined cells.                           | CW-Complex                                  |
| **Manifold&lt;K, F&gt;**             | A complex `K: ChainComplex` + field `F` + optional `K::Metric` + cursor.          | Discrete manifold over $K$                  |
| **SimplicialManifold&lt;C, F&gt;**   | Alias for `Manifold<SimplicialComplex<C>, F>` (the textbook simplicial case).     | (specialization)                            |
| **Chain**                            | Formal sum of simplices for algebraic topology.                                   | Chain Group $C_n$                           |
| **Skeleton**                         | k-skeleton of a complex (simplices up to dim k).                                  | Skeleton $K^{(k)}$                          |
| **Simplex**                          | Basic building block (vertex, edge, triangle...).                                 | $n$-Simplex                                 |
| **Topology**                         | Abstract topological space with graded data.                                      | Graded Vector Space                         |
| **DifferentialForm**                 | Discrete differential k-forms on a complex.                                       | $\Omega^k(M)$                               |
| **CurvatureTensor**                  | Riemann/Ricci curvature tensor.                                                   | $R^{\mu}_{\nu\rho\sigma}$                   |
| **ReggeGeometry&lt;T&gt;**           | Simplicial metric (edge lengths, deficit angles). Implements `Manifold` `Metric`. | Regge Calculus                              |
| **CubicalReggeGeometry&lt;D&gt;**           | Cubical analogue of Regge geometry on a `LatticeComplex<D>` (Stage C: edge-length storage + signature; derived volumes / deficit angles / Hodge ⋆ forward-looking). | Cubical Regge calculus                      |
| **GaugeField**                       | Gauge field on a manifold (connections).                                          | Principal Bundle Connection                 |
| **LatticeGaugeField**                | Wilson-formulation lattice gauge theory (physics term, retained).                 | $U_\mu(n) \in G$                            |
| **LinkVariable**                     | Group element on a lattice edge.                                                  | $\text{SU}(N)$ Element                      |

### Traits

| Trait                          | Purpose                                                                                              |
|:-------------------------------|:-----------------------------------------------------------------------------------------------------|
| **`ChainComplex`**             | Unifies `SimplicialComplex`, `LatticeComplex`, `CellComplex`. Exposes cell iteration (GAT, static dispatch), `boundary_matrix(k)` / `coboundary_matrix(k)` returning `Cow<'_, CsrMatrix<i8>>`, `betti_number(k)`, and an associated `Metric` type. |
| **`Cell`**                     | Marker for elementary cells: `dim()` + signed `boundary()` chain.                                    |
| **`Neighborhood<K>`**          | Static-dispatch strategy for enumerating cell neighbors. Concrete impls: `FaceAdjacent`, `CofaceAdjacent`, `VonNeumann`, `Moore`, `KRing<const K>`. |
| **`BaseTopology`, `SimplicialTopology`, `ManifoldTopology`, `GraphTopology`, `HypergraphTopology`** | Capability-graded topology queries.                |

## Mathematical Naming Convention

This crate uses dual names only where the same mathematical object lives at the intersection of two equally-canonical traditions — never as a back-compat shim or cosmetic preservation. The principle, applied object by object:

### `LatticeComplex<D>` ↔ `CubicalComplex<D>`

The struct stores `shape: [usize; D] + periodic: [bool; D]` — a **regular $\mathbb{Z}^D$ grid**, with elementary cubes computed on demand. Two mathematical traditions describe this same object, each emphasizing a different structural layer:

- **Physics / number theory: "lattice."** Meaning #3 in standard math vocabulary — a regular integer grid such as $\mathbb{Z}^D$ or a bounded box thereof. The substrate-emphasizing name. Used by `LatticeGaugeField`, lattice QCD, the Ising model, crystallography.
- **Algebraic topology: "cubical complex."** Kaczynski–Mischaikow–Mrozek (*Computational Homology*, 2004, Def. 2.36) and Edelsbrunner–Harer (*Computational Topology*). The cellular-decomposition-emphasizing name — the cubes are products of degenerate and non-degenerate intervals (which is exactly what the orientation bitmask on `LatticeCell<D>` encodes).

Both names are equally canonical for what they emphasize. `LatticeComplex<D>` is the declared type; `CubicalComplex<D>` is a `pub type` alias on it. Use whichever name fits the surrounding text — neither is a "primary" choice over the other.

The same dual-name principle applies to the elementary cell: **`LatticeCell<D>` ↔ `CubicalCell<D>`**. No other aliases exist in the lattice family — types like `DualLatticeComplex<D>`, `LatticeComplexWitness<D>`, or the per-axis iterators have only their canonical name because there is no genuinely distinct cubic-specialization reading for them.

**Scope note.** `LatticeComplex<D>` represents specifically the cubical complex of a *regular* $\mathbb{Z}^D$ grid. It is **not** a sparse cubical complex (only-active-cubes) or an irregular one (cubes of varying side lengths) — those are deferred follow-ups.

### `ReggeGeometry<T>` ↔ `CubicalReggeGeometry<D>`

These are parallel by role, not by alias: each is the discrete-geometry / metric data on its respective complex, and each is named after the **same construction** (Regge calculus) transported to a different cellular world:

- **`ReggeGeometry<T>`** — Tullio Regge's original 1961 construction for simplicial complexes: edge lengths plus deficit angles on codimension-2 hinges, yielding a discrete general relativity.
- **`CubicalReggeGeometry<D>`** — the same construction on a cubical complex. Sometimes called "cubical Regge calculus" or "hypercubic Regge calculus" in the lattice quantum gravity literature. Stage C ships the edge-length storage layer (unit / isotropic / per-axis / per-edge) and the Lorentzian-signature computation; cell volumes, deficit angles, Hodge ⋆, and per-cell metric tensors are forward-looking and tracked as a follow-up.

The naming is parallel because the *math* is parallel.

### `Manifold<K: ChainComplex, F>` ↔ `SimplicialManifold<C, F>`

The struct is generic over the underlying chain complex `K` and the field data type `F`:

- **`Manifold<K, F>`** — the general form. `K` can be any `ChainComplex` (currently `SimplicialComplex<C>`, `LatticeComplex<D>`, `CellComplex<C>`, or user-defined). The optional metric is typed via `K::Metric` (the associated type on `ChainComplex`), so a simplicial manifold carries `Option<ReggeGeometry<C>>` and a lattice manifold carries `Option<CubicalReggeGeometry<D>>` — with no `dyn`, no enum, no runtime dispatch.
- **`SimplicialManifold<C, F>` = `Manifold<SimplicialComplex<C>, F>`** — alias for the textbook simplicial case. Existing simplicial code uses this name unchanged.

### `ChainComplex` (was `CWComplex`)

The trait was renamed to align with algebraic-topology textbook usage. *Chain complex* is the standard term for a sequence of abelian groups (here, free $\mathbb{Z}$-modules generated by k-cells) connected by boundary operators with $\partial \circ \partial = 0$. The previous name `CWComplex` referred more narrowly to the underlying CW (Closure-finite, Weak topology) cellular structure. Functionally identical; just the textbook-correct name.

## Lattice Gauge Field Verification ✓

The `LatticeGaugeField` implementation is verified against known results from lattice gauge theory
(M. Creutz, *Quarks, Gluons and Lattices*, Cambridge 1983).

**24 Physics Verification Tests:**

| Category | Tests | Verification |
|----------|-------|--------------|
| **2D U(1) Exact Solution** | 3 | Identity ⟨P⟩ = 1.0, Wilson S = 0, Bessel I₁/I₀ algorithm agreement |
| **Coupling Limits** | 2 | Strong coupling ⟨P⟩ ≈ β/2, Weak coupling ⟨P⟩ → 1 |
| **Wilson/Polyakov Loops** | 2 | W(R,T) = 1 and P = 1 for identity configuration |
| **Improved Actions** | 4 | Symanzik (c₁=-1/12), Iwasaki (c₁=-0.331), DBW2 (c₁=-1.4088), normalization c₀+8c₁=1 |
| **Lattice Structure** | 3 | Plaquette counting correct in 2D, 3D, 4D |
| **Gauge Invariance** | 2 | Wilson action and ⟨P⟩ invariant under random gauge transforms |
| **Topology Detection** | 3 | Perturbation detection, random vs identity action, 4D topological charge Q=0 |
| **Thermalization** | 3 | Hot/cold start difference, Metropolis sweep runs, field modification |
| **Anisotropy** | 2 | Plaquette orientation detection (temporal vs spatial), local perturbation effect |

Run verification tests:
```bash
cargo test -p deep_causality_topology verification_tests --release
```

## Usage

Add this crate to your `Cargo.toml`:

```toml
deep_causality_topology = { version = "0.1" }
```

### 1. Basic Graph Construction

Efficiently model causal dependencies using sparse adjacency matrices.

```rust
use deep_causality_sparse::CsrMatrix;
use deep_causality_tensor::CausalTensor;
use deep_causality_topology::{Graph, GraphTopology};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Adjacency: 0->1, 1->2
    let adj = CsrMatrix::from_triplets(3, 3, &[(0, 1, 1), (1, 2, 1)])?;
    let data = CausalTensor::new(vec![1.0, 2.0, 3.0], vec![3])?;

    let graph = Graph::new(adj, data, 0)?;

    println!("Neighbors of 1: {:?}", graph.get_neighbors(1)?);
    Ok(())
}
```

### 2. Manifold Analysis (Euler Characteristic)

Validate geometric shapes and compute topological invariants.

```rust
use deep_causality_topology::{Manifold, SimplicialComplex, Simplex, Skeleton};
// ... (Setup complex) ...

// Compute Euler Characteristic: Chi = V - E + F ...
let chi = manifold.euler_characteristic();
// Chi = 1 (Contractible/Solid)
// Chi = 0 (Hole/Circle)
// Chi = 2 (Sphere)
```

### 3. Point Cloud Triangulation (i.e. MRI Image Analysis)

Convert raw sensor data into structured geometry to detect anomalies (e.g., tumors/voids).

```rust
use deep_causality_topology::PointCloud;

// 1. Ingest Raw MRI Data
let pc = PointCloud::new(points_tensor, metadata, 0) ?;

// 2. Triangulate (Vietoris-Rips)
let complex = pc.triangulate(0.6) ?;

// 3. Diagnose based on Topology
let chi = complex.euler_characteristic();
if chi <= 0 {
println ! ("Pathological: Detected Void/Necrosis");
}
```

### 4. Differential Geometry (Heat Equation)

Simulate physical processes like diffusion on complex geometries using the Hodge-Laplacian.

```rust
use deep_causality_topology::{Manifold, PointCloud};
// ... (Setup manifold from a PointCloud) ...

// Set initial heat distribution (a 0-form)
// ...

// Time-step the heat equation: ∂u/∂t = -Δu
for _ in 0..num_steps {
let laplacian = manifold.laplacian(0);
// ... update data using: new_data = current_data - dt * laplacian
}
```

## Higher-Kinded Types (HKT)

This crate leverages `deep_causality_haft` to provide functional geometric abstractions.

* **Functor**: Map functions over the data stored in the topology (e.g., transform node weights).
* **BoundedComonad (Extract/Extend)**:
    * *Extract*: Get the value at the current "cursor" (focus).
    * *Extend*: Apply a local computation (convolution) over the neighborhood of every point to produce a new topology.
      This is the foundation of **Graph Neural Networks (GNNs)** and **Cellular Automata**.
* **BoundedAdjunction (Unit/Counit)**:
    * *Unit*: Embed discrete data into a topological structure.
    * *Counit*: Project/Integrate topological data back into a flat representation.

### Witnesses

| Witness                          | Operates on                              | HKT impls available                            |
|:---------------------------------|:-----------------------------------------|:-----------------------------------------------|
| `SimplicialManifoldWitness<C>`   | `SimplicialManifold<C, _>`               | `HKT`, `Functor`, `Foldable`, `Pure`, `Monad`, `Applicative`, `CoMonad` |
| `GenericManifoldWitness<K>`      | `Manifold<K, _>` for any `K: ChainComplex` | `HKT`, `Functor` (others deferred to follow-up) |
| `LatticeComplexWitness<D>` | `LatticeComplex<D>` HKT plumbing | `HKT` and related                              |
| Graph / Hypergraph / PointCloud / CellComplex / Topology / Chain witnesses | Their namesake types        | Per-type capability set                        |

## Examples

| File Name                      | Description                             | Engineering Value                                                  |
|:-------------------------------|:----------------------------------------|:-------------------------------------------------------------------|
| `basic_graph.rs`               | Graph construction & traversal          | Foundation for large-scale causal network modeling.                |
| `manifold_analysis.rs`         | 1-Manifold validation & Euler Char.     | Ensuring geometric validity for differential operators.            |
| `point_cloud_triangulation.rs` | MRI Tissue Segmentation                 | Bridging raw sensor data with topological reasoning for diagnosis. |
| `chain_algebra.rs`             | Chain complex algebra & `∂∂=0`          | Foundational verification for homological algebra.                 |
| `differential_field.rs`        | Solving the Heat Equation on a manifold | Simulating physical diffusion processes on complex shapes.         |
| `hodge_theory.rs`              | Finding harmonic forms to detect holes  | Advanced topological feature detection using the Hodge-Laplacian.  |
| `cubical_heat_diffusion.rs`    | Heat equation on a `CubicalComplex<2>` via Moore neighborhood + CoMonad-style stencil | Voxel-grid sensor fusion and grid-native physics simulation. |
| `lattice_gauge_simulation.rs`  | 4D SU(3) lattice gauge field simulation | Wilson-formulation lattice QCD prototyping.                        |

To run examples:

```bash
cargo run -p deep_causality_topology --example point_cloud_triangulation
```

## Contribution

Contributions are welcomed especially related to documentation, example code, and fixes.
If unsure where to start, just open an issue and ask.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in deep_causality by you,
shall be licensed under the MIT licence, without any additional terms or conditions.

## Licence

This project is licensed under the [MIT license](LICENSE).

## Security

For details about security, please read
the [security policy](https://github.com/deepcausality-rs/deep_causality/blob/main/SECURITY.md).
