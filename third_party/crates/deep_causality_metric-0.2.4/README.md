# deep_causality_metric

Metric signature types and sign conventions for Clifford algebras and physics.

## Overview

This crate provides a foundational set of types for working with metric signatures in Clifford algebras Cl(p, q, r), Riemannian geometry, and physics applications.

### Key Features

- **Single Source of Truth**: Consolidates all metric signature logic into one crate
- **Zero Dependencies**: Serves as a foundational leaf crate in the dependency graph
- **Type-Safe Conventions**: Compile-time enforcement of physics sign conventions
- **Cross-Crate Integration**: Enables consistent metric handling across multivector, tensor, topology, and physics crates

## Core Types

| Type | Description |
|------|-------------|
| `Metric` | Core signature enum Cl(p, q, r) |
| `MetricError` | Error type for metric operations |
| `LorentzianMetric` | Trait for convention wrappers |
| `EastCoastMetric` | (-+++) convention newtype |
| `WestCoastMetric` | (+---) convention newtype |

## Sign Conventions

| Convention | Signature | g_{μν} | Used By |
|------------|-----------|--------|---------|
| East Coast | (-+++) | diag(-1,1,1,1) | MTW, GR textbooks |
| West Coast | (+---) | diag(1,-1,-1,-1) | Weinberg, Particle physics |

### Type Aliases

For domain-specific clarity:

| Alias | Target | Domain |
|-------|--------|--------|
| `RelativityMetric` | `EastCoastMetric` | General Relativity |
| `ParticleMetric` | `WestCoastMetric` | Particle Physics |
| `PhysicsMetric` | `RelativityMetric` | Default (GR) |

## Usage

### Basic Metric Operations

```rust
use deep_causality_metric::Metric;

// Create a standard 4D Minkowski metric (West Coast convention)
let minkowski = Metric::Minkowski(4);
assert_eq!(minkowski.dimension(), 4);
assert_eq!(minkowski.sign_of_sq(0), 1);   // time is +1
assert_eq!(minkowski.sign_of_sq(1), -1);  // space is -1

// Get signature tuple (p, q, r)
assert_eq!(minkowski.signature(), (1, 3, 0));

// Create from signature
let euclidean = Metric::from_signature(3, 0, 0);
assert_eq!(euclidean, Metric::Euclidean(3));
```

### Type-Safe Convention Wrappers

```rust
use deep_causality_metric::{EastCoastMetric, WestCoastMetric, LorentzianMetric};

// East Coast convention (-+++) for General Relativity
let east = EastCoastMetric::minkowski_4d();
assert_eq!(east.time_sign(), -1);
assert_eq!(east.space_sign(), 1);
assert!(east.is_east_coast());

// West Coast convention (+---) for Particle Physics
let west = WestCoastMetric::minkowski_4d();
assert_eq!(west.time_sign(), 1);
assert_eq!(west.space_sign(), -1);
assert!(west.is_west_coast());
```

### Convention Conversion

```rust
use deep_causality_metric::{Metric, EastCoastMetric, WestCoastMetric};

// Convert from West Coast to East Coast
let west = Metric::Minkowski(4);
let east = EastCoastMetric::from_west_coast(west).unwrap();

// Convert back
let west_again = WestCoastMetric::from_east_coast(east.into_metric()).unwrap();
```

### Using Type Aliases

```rust
use deep_causality_metric::{RelativityMetric, ParticleMetric, MINKOWSKI_4D};

// For GR code
fn relativistic_calculation(metric: RelativityMetric) {
    // Uses East Coast convention internally
    assert!(metric.is_east_coast());
}

// For particle physics code
fn particle_calculation(metric: ParticleMetric) {
    // Uses West Coast convention internally
    assert!(metric.is_west_coast());
}
```

## Mathematical Background

### Clifford Algebra Signature

A Clifford algebra Cl(p, q, r) over ℝⁿ where n = p + q + r is defined by:

$$e_i \cdot e_j + e_j \cdot e_i = 2g_{ij}$$

where the metric tensor g has:
- p eigenvalues of +1
- q eigenvalues of -1
- r eigenvalues of 0 (degenerate)

### Metric Variants

| Variant | Signature | Example Uses |
|---------|-----------|--------------|
| `Euclidean(n)` | (n, 0, 0) | Standard ℝⁿ |
| `NonEuclidean(n)` | (0, n, 0) | Anti-Euclidean |
| `Minkowski(n)` | (1, n-1, 0) | Spacetime (West Coast) |
| `PGA(n)` | (n-1, 0, 1) | Projective Geometric Algebra |
| `Generic{p,q,r}` | (p, q, r) | General Cl(p,q,r) |
| `Custom{...}` | bitmask | Up to 64 dimensions |

## Feature Flags

| Feature | Default | Description |
|---------|---------|-------------|
| `std` | ✓ | Standard library support |
| `alloc` | ✓ | Allocation support (via std) |

For `no_std` environments, disable default features:

```toml
[dependencies]
deep_causality_metric = { version = "0.1", default-features = false, features = ["alloc"] }
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

