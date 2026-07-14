/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#![cfg_attr(not(feature = "std"), no_std)]
extern crate core;

// Private re-exports of `deep_causality_num` core symbols so that the moved
// `algebra` and `iso` modules keep resolving them through `crate::` paths.
use deep_causality_num::{Float, FromPrimitive, One, Zero};

mod algebra;
pub mod iso;
pub mod utils_tests;

// Algebra types
pub use crate::algebra::algebra_assoc::AssociativeAlgebra;
pub use crate::algebra::algebra_assoc_div::AssociativeDivisionAlgebra;
pub use crate::algebra::algebra_base::Algebra;
pub use crate::algebra::algebra_div::DivisionAlgebra;
pub use crate::algebra::associative::Associative;
pub use crate::algebra::bounded_semilattice::BoundedSemilattice;
pub use crate::algebra::commutative::Commutative;
pub use crate::algebra::commutative_monoid::CommutativeMonoid;
pub use crate::algebra::conjunction::Conjunction;
pub use crate::algebra::count::Count;
pub use crate::algebra::disjunction::Disjunction;
pub use crate::algebra::distributive::Distributive;
pub use crate::algebra::field::Field;
pub use crate::algebra::field_complex::ComplexField;
pub use crate::algebra::field_real::RealField;
pub use crate::algebra::group::Group;
pub use crate::algebra::group_abelian::AbelianGroup;
pub use crate::algebra::group_add::AddGroup;
pub use crate::algebra::group_div::DivGroup;
pub use crate::algebra::group_mul::MulGroup;
pub use crate::algebra::group_semi::{AddSemigroup, MulSemigroup};
pub use crate::algebra::idempotent::Idempotent;
pub use crate::algebra::magma::{AddMagma, MulMagma};
pub use crate::algebra::module::Module;
pub use crate::algebra::monoid::{AddMonoid, InvMonoid, MulMonoid};
pub use crate::algebra::monoid_generic::Monoid;
pub use crate::algebra::normed::Normed;
pub use crate::algebra::prob::Prob;
pub use crate::algebra::real::Real;
pub use crate::algebra::ring::Ring;
pub use crate::algebra::ring_associative::AssociativeRing;
pub use crate::algebra::ring_commutative::CommutativeRing;
pub use crate::algebra::rotation::Rotation;
pub use crate::algebra::scalar::Scalar;
pub use crate::algebra::scalar_conjugate::ConjugateScalar;
pub use crate::algebra::scalar_normed::NormedScalar;
pub use crate::algebra::verdict::Verdict;

// Isomorphism traits
pub use crate::iso::{AlgebraIso, DivisionAlgebraIso, FieldIso, GroupIso, RingIso};
