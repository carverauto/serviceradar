/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # Algebraic Traits
//!
//! This module provides a comprehensive hierarchy of algebraic structures, enabling type-safe
//! representation of mathematical systems from basic magmas to complex division algebras.
//!
//! ## Core Hierarchy Overview
//!
//! 1. **Foundational Structures**: `Magma` (closure) → `Semigroup` (associativity) → `Monoid` (identity)
//! 2. **Additive Hierarchy**: `AddMonoid` → `AddGroup` (inverses) → `AbelianGroup` (commutative)
//! 3. **Multiplicative Hierarchy**: `MulMonoid` → `InvMonoid` (inverses) → `MulGroup`
//! 4. **Ring structures**: `Ring` (AbelianGroup + MulMonoid + Distributive) → `CommutativeRing`
//! 5. **Domain structures**: `EuclideanDomain` (division with remainder, GCD)
//! 6. **Field structures**: `Field` (CommutativeRing + division) → `RealField` (calculus) → `ComplexField`
//! 7. **Vector structures**: `Module` → `Algebra` → `DivisionAlgebra`
//!
//! ## Trait Reference
//!
//! ### Marker Traits
//!
//! Marker traits encode fundamental algebraic laws. Implementing them is a compile-time
//! promise that the type satisfies the corresponding mathematical property.
//!
//! | Trait | Property | Law |
//! |-------|----------|-----|
//! | **Associative** | Associativity | `(a · b) · c = a · (b · c)` |
//! | **Commutative** | Commutativity | `a · b = b · a` |
//! | **Distributive** | Distributivity | `a · (b + c) = a · b + a · c` |
//!
//! ### Foundational Structures
//!
//! * **Magma** (`AddMagma`, `MulMagma`): A set with a closed binary operation.
//! * **Semigroup** (`AddSemigroup`, `MulSemigroup`): A magma where the operation is associative.
//! * **Monoid** (`AddMonoid`, `MulMonoid`): A semigroup with an identity element (`Zero` or `One`).
//!
//! ### Groups
//!
//! * **AddGroup**: An additive monoid where every element has an additive inverse (`-a`).
//! * **AbelianGroup**: An `AddGroup` where addition is commutative.
//! * **MulGroup**: A multiplicative monoid where non-zero elements have inverses (`1/a`).
//!
//! ### Rings and Domains
//!
//! * **Ring**: An `AbelianGroup` under addition and a `MulMonoid` under multiplication, satisfying distributivity.
//! * **CommutativeRing**: A ring where multiplication is commutative.
//! * **EuclideanDomain**: A commutative ring with a Euclidean function enabling division with remainder and GCD algorithms.
//!
//! ### Fields
//!
//! * **Field**: A commutative ring where every non-zero element has a multiplicative inverse.
//! * **RealField**: A field with ordering and transcendental functions (sqrt, exp, ln, sin, cos).
//! * **ComplexField**: A field extension over the reals supporting complex conjugation and components.
//!
//! ### Vector and Division Algebras
//!
//! * **Module**: A generalization of vector spaces defined over a ring.
//! * **Algebra**: A module equipped with a bilinear product (e.g., Complex, Quaternion).
//! * **DivisionAlgebra**: An algebra where every non-zero element has a multiplicative inverse.
//! * **Rotation**: Specialized trait for types performing 3D rotations or phase transitions.
//!
pub mod algebra_assoc;
pub mod algebra_assoc_div;
pub mod algebra_base;
pub mod algebra_div;
pub mod associative;
pub mod commutative;
pub mod distributive;
pub mod domain_euclidean;
pub mod field;
pub mod field_complex;
pub mod field_real;
pub mod group;
pub mod group_abelian;
pub mod group_add;
pub mod group_div;
pub mod group_mul;
pub mod magma;
pub mod module;
pub mod monoid;
pub mod normed;
pub mod real;
pub mod ring;
pub mod ring_associative;
pub mod ring_commutative;
pub(crate) mod rotation;
pub mod scalar;
pub mod semigroup;
