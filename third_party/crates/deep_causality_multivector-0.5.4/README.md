# DeepCausality Multivector

A dynamic, universal Clifford Algebra implementation for Rust, designed for theoretical physics, causal modeling, and
geometric algebra applications.

## Features

* **Dynamic Metric Signature**: Supports arbitrary signatures $Cl(p, q, r)$ at runtime via the `Metric` enum.
    * Euclidean, Non-Euclidean, Minkowski, PGA, and Custom signatures.
* **Universal Multivector**: A single type `CausalMultiVector<T>` can represent scalars, vectors, bivectors, and
  higher-grade blades.
* **Comprehensive Operations**:
    * Geometric Product, Outer Product, Inner Product (Left Contraction).
    * Reversion, Squared Magnitude, Inverse, Dual.
    * Grade Projection.
* **Higher-Kinded Types (HKT)**: Implements `Functor`, `Applicative`, and `Monad` (via `deep_causality_haft`) for
  advanced functional patterns.
    * `Monad::bind` implements the **Tensor Product** of algebras.

## Pre-configured Algebras

### Complex

Algebras:

* **$Cl_{\mathbb{C}}(2)$ (Complex Quaternions)**: The minimal complex Clifford algebra, often used
  for $\mathfrak{spin}(3, 1)$ representations.
* **$Cl_{\mathbb{C}}(4)$ (Quaternion Operator Algebra)**: Hosts
  the $\mathfrak{spin}(4) \sim \mathfrak{su}(2)_L \oplus \mathfrak{su}(2)_R$ electroweak
  symmetries. ($\mathcal{M}_{\mathbb{H}}$)
* **$Cl_{\mathbb{C}}(6)$ (Octonion Operator Algebra)**: Hosts the $\mathfrak{spin}(6) \sim \mathfrak{su}(4)$ Pati-Salam
  symmetries, and the colour group $\mathfrak{su}(3)_C$. ($\mathcal{L}_{\mathbb{O}}$)
* **$Cl_{\mathbb{C}}(8)$ (Dixon Left Multiplication Algebra)**: Hosts $\mathfrak{spin}(8)$
  triality. ($\mathcal{L}_{\mathcal{A}}$)
* **$Cl_{\mathbb{C}}(10)$ (Grand Unified Algebra)**: Hosts the full $\mathfrak{spin}(10)$ gauge
  symmetry. ($\mathcal{M}_{\mathcal{A}}$)

Type: `ComplexMultiVector`

| Algebra (Contextual Name) | Canonical Signature | Constructor / Alias                                            |
|:--------------------------|:--------------------|:---------------------------------------------------------------|
| **Complex Quaternions**   | $Cl(2, 0)$          | `new_complex_pauli` (Alias for `new_complex_clifford_2`)       |
| **Quaternion Operator**   | $Cl(0, 4)$          | `new_quaternion_operator` (Alias for `new_complex_clifford_4`) |
| **Octonion Operator**     | $Cl(0, 6)$          | `new_octonion_operator` (Alias for `new_complex_clifford_6`)   |
| **Dixon Left Mult. Alg.** | $Cl(0, 8)$          | `new_dixon_algebra_left` (Alias for `new_complex_clifford_8`)  |
| **Grand Unified Algebra** | $Cl(0, 10)$         | `new_gut_algebra` (Alias for `new_complex_clifford_10`)        |

### Real

Algebras:

* $Cl(N, 0)$: Generic N-dimensional Euclidean algebra.
* $Cl(0, 1)$: Isomorphic to Complex Numbers $\mathbb{C}$.
* $Cl(1, 0)$: Isomorphic to Split-Complex (Hyperbolic) Numbers.
* $Cl(0, 2)$: Isomorphic to Quaternions $\mathbb{H}$.
* $Cl(2, 0)$: Isomorphic to Split-Quaternions (Coquaternions) / $\text{Mat}(2, \mathbb{R})$.
* $Cl(3, 0)$: Algebra of Physical Space (APS) / Pauli Algebra.
* $Cl(1, 3)$ / $Cl(3, 1)$: Space-Time Algebra (STA) / Dirac Algebra (with two different conventions).
* $Cl(4, 1)$: Conformal Geometric Algebra (CGA).

Type: `RealMultiVector`

| Algebra (Common Name)     | Signature  | Convention        | Constructor / Alias                          |
|:--------------------------|:-----------|:------------------|:---------------------------------------------|
| **Euclidean Vectors**     | $Cl(N, 0)$ | N-dim Euclidean   | `RealMultiVector::new_euclidean`             |
| **Complex Numbers**       | $Cl(0, 1)$ |                   | `RealMultiVector::new_complex_number`        |
| **Split Complex Numbers** | $Cl(1, 0)$ |                   | `RealMultiVector::new_split_complex`         |
| **Quaternions**           | $Cl(0, 2)$ |                   | `RealMultiVector::new_quaternion`            |
| **Split Quaternions**     | $Cl(2, 0)$ |                   | `RealMultiVector::new_split_quaternion`      |
| **Pauli (APS)**           | $Cl(3, 0)$ |                   | `RealMultiVector::new_aps_vector`            |
| **Spacetime (STA)**       | $Cl(1, 3)$ | Physics (+ - - -) | `RealMultiVector::new_spacetime_algebra_1_3` |
| **Spacetime (STA)**       | $Cl(3, 1)$ | Math/GR (- + + +) | `RealMultiVector::new_spacetime_algebra_3_1` |
| **Conformal (CGA)**       | $Cl(4, 1)$ |                   | `RealMultiVector::new_cga_vector`            |

### Quantum State Vector (HilbertState)

The `HilbertState` type represents a quantum state vector (ket) $|\psi\rangle$ within a Clifford Algebra.
It acts as a strong type for elements of a minimal left ideal of the algebra, which serves as the Hilbert space.

* **Coefficients**: Always `Complex<f64>`.
* **Metric**: Fixed at construction, typically `Cl(0,10)` (NonEuclidean, 10D) for the Grand Unified
  Algebra ($\mathfrak{spin}(10)$).

This ensures type safety and prevents mixed-algebra operations, crucial for consistent quantum mechanical calculations
within the algebraic framework.

Type: `HilbertState` (Alias for `CausalMultiVector<Complex<f64>>` with specific constructors)

| Alias (Contextual Name)  | Canonical Signature | Constructor / Alias                              |
|:-------------------------|:--------------------|:-------------------------------------------------|
| **Quantum State Vector** | $Cl(0, 10)$         | `HilbertState::new_spin10` (enforces $Cl(0,10)$) |
| **Generic Qubit/State**  | Arbitrary           | `HilbertState::new` (allows any Metric)          |

### 3D Projective Geometric Algebra

Type: PGA3DMultiVector

| Algebra    | Signature     | Constructor / Alias           |
|:-----------|:--------------|:------------------------------|
| **PGA 3D** | $Cl(3, 0, 1)$ | `PGA3DMultiVector::new_point` |

## Custom Algebras

1) Define a custom metric
2) Instantiate either a real, complex, or custom typed MultiVector with the metric
3) Done

```
use deep_causality_multivector::{RealMultiVector, Metric};

   // Some data 
   let data = vec![0.0; 16];

   // Define a custom metric. See docs for Metrics about Generic or Custom metric type 
   let metric =  Metric::Custom {
                dim: 4,
                neg_mask: 1,
                zero_mask: 0,
            },

   // Instantaiate your custom algebra over a RealMultiVector
   let a = RealMultiVector::new(data_a,metric ).unwrap();
```

## Usage

Add this crate to your `Cargo.toml`.

```toml
deep_causality_multivector = { version = "0.1" }
```

### Basic Operations

```rust
use deep_causality_multivector::{CausalMultiVector, Metric};

fn main() {
    // Create two vectors in 2D Euclidean space

    let mut data_a = vec![0.0; 4];
    data_a[1] = 1.0; // 1.0 * e1
    let a = CausalMultiVector::new_euclidean(data_a).unwrap();

    let mut data_b = vec![0.0; 4];
    data_b[2] = 1.0; // 1.0 * e2
    let b = CausalMultiVector::new_euclidean(data_b).unwrap();

    // Geometric Product: e1 * e2 = e12
    let product = a * b;
    println!("e1 * e2 = e12 coefficient: {}", product.get(3).unwrap());
}
```

### Using Aliases (e.g., PGA)

```rust
use deep_causality_multivector::PGA3DMultiVector;

fn main() {
    // Create a point in 3D PGA (Dual representation)
    let point = PGA3DMultiVector::new_point(1.0, 2.0, 3.0);

    // Create a translator (Motor)
    let translator = PGA3DMultiVector::translator(2.0, 0.0, 0.0); // Shift x by 2

    // Apply transformation: P' = T * P * ~T
    let t_rev = translator.reversion();
    let transformed = translator.clone() * point * t_rev;

    println!("Transformed X: {}", transformed.get(13).unwrap()); // e032 component
}
```

### Higher-Kinded Types (HKT)

This crate implements HKT traits from `deep_causality_haft`.

* **Functor**: Map a function over coefficients.
* **Applicative**: Lift values and apply functions.
* **Monad**: Tensor product of algebras.

```rust

use deep_causality_haft::{Applicative, Functor, Monad};
use deep_causality_multivector::{CausalMultiVector, Metric, CausalMultiVectorWitness};

fn main() {
    println!("=== Higher-Kinded Types (HKT) with CausalMultiVector ===");

    // 1. Functor: Mapping over coefficients
    println!("\n--- Functor (Map) ---");
    let v = CausalMultiVector::new_euclidean(vec![1.0, 2.0, 3.0, 4.0]).unwrap();
    println!("Original Vector: {:?}", v.data);

    // Scale by 2.0 using fmap
    let scaled = CausalMultiVectorWitness::fmap(v.clone(), |x| x * 2.0);
    println!("Scaled Vector (x2): {:?}", scaled.data);
    assert_eq!(scaled.data, vec![2.0, 4.0, 6.0, 8.0]);

    // 2. Applicative: Broadcasting a function
    println!("\n--- Applicative (Apply/Broadcast) ---");
    // Create a "pure" function wrapped in a scalar multivector
    let pure_fn = CausalMultiVectorWitness::pure(|x: f64| x + 10.0);

    // Apply it to our vector
    let shifted = CausalMultiVectorWitness::apply(pure_fn, v.clone());
    println!("Shifted Vector (+10): {:?}", shifted.data);
    assert_eq!(shifted.data, vec![11.0, 12.0, 13.0, 14.0]);

    // 3. Monad: Tensor Product via Bind    
    //...
    // See examples/hkt_usage.rs for full demonstration
}
```

## Examples

| File Name                     | Used Algebra                                         | Description                                                                                                                                   |
|:------------------------------|:-----------------------------------------------------|:----------------------------------------------------------------------------------------------------------------------------------------------|
| `basic_multivector.rs`        | `CausalMultiVector` (`Euclidean(2)`)                 | Demonstrates basic geometric algebra operations (geometric, outer, inner product, inverse) in a 2D Euclidean space.                           |
| `clifford_mhd_multivector.rs` | `CausalMultiVector` (`Euclidean(3)`, `Minkowski(4)`) | Simulates Lorentz force in plasma fusion using both Euclidean and Minkowski metrics for metric-agnostic calculations.                         |
| `dixon_multivector.rs`        | `DixonAlgebra` (Cl_C(6))                             | Demonstrates operations within the Dixon Algebra, including basis vector construction, geometric products, and complex scalar multiplication. |
| `hkt_multivector.rs`          | `CausalMultiVector` (`Euclidean`)                    | Demonstrates Higher-Kinded Types (HKT) including Functor, Applicative, and Monad implemented for `CausalMultiVector`.                         |
| `pga3d_multivector.rs`        | `PGA3DMultiVector` (3D PGA)                          | Demonstrates 3D Projective Geometric Algebra (PGA) by creating a point, a translator (motor), and applying transformations.                   |

## Benchmarks

Performance measured on Apple M3 Max.

| Operation             | Metric       | Time (Median) |
|:----------------------|:-------------|:--------------|
| **Geometric Product** | Euclidean 2D | ~89.6 ns      |
| **Geometric Product** | PGA 3D       | ~87.5 ns      |
| **Addition**          | Euclidean 3D | ~39.1 ns      |
| **Reversion**         | PGA 3D       | ~37.3 ns      |

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

