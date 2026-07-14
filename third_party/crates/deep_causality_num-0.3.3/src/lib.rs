/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#![cfg_attr(not(feature = "std"), no_std)]
extern crate core;

mod algebra;
mod alias;
mod cast;
mod complex;
mod dual;
mod float;
mod float_106;
mod float_option;
mod integer;
pub mod iso;
mod num;
pub mod utils_tests;

// Algebra types
pub use crate::algebra::algebra_assoc::AssociativeAlgebra;
pub use crate::algebra::algebra_assoc_div::AssociativeDivisionAlgebra;
pub use crate::algebra::algebra_base::Algebra;
pub use crate::algebra::algebra_div::DivisionAlgebra;
pub use crate::algebra::associative::Associative;
pub use crate::algebra::commutative::Commutative;
pub use crate::algebra::distributive::Distributive;
pub use crate::algebra::domain_euclidean::EuclideanDomain;
pub use crate::algebra::field::Field;
pub use crate::algebra::field_complex::ComplexField;
pub use crate::algebra::field_real::RealField;
pub use crate::algebra::group::Group;
pub use crate::algebra::group_abelian::AbelianGroup;
pub use crate::algebra::group_add::AddGroup;
pub use crate::algebra::group_div::DivGroup;
pub use crate::algebra::group_mul::MulGroup;
pub use crate::algebra::magma::{AddMagma, MulMagma};
pub use crate::algebra::module::Module;
pub use crate::algebra::monoid::{AddMonoid, InvMonoid, MulMonoid};
pub use crate::algebra::normed::Normed;
pub use crate::algebra::real::Real;
pub use crate::algebra::ring::Ring;
pub use crate::algebra::ring_associative::AssociativeRing;
pub use crate::algebra::ring_commutative::CommutativeRing;
pub use crate::algebra::rotation::Rotation;
pub use crate::algebra::scalar::Scalar;
pub use crate::algebra::semigroup::{AddSemigroup, MulSemigroup};

// Alias types
pub use crate::alias::{Matrix3, Vector3};

// Casts
pub use crate::cast::as_primitive::AsPrimitive;
pub use crate::cast::as_scalar::float_as_scalar_impl::FloatAsScalar;
pub use crate::cast::as_scalar::int_as_scalar_impl::IntAsScalar;
pub use crate::cast::from_primitive::FromPrimitive;
pub use crate::cast::num_cast::NumCast;
pub use crate::cast::to_float::{FloatFromInt, IntoFloat};
pub use crate::cast::to_primitive::ToPrimitive;

//  Complex number types
pub use crate::complex::complex_number::{Complex, Complex32, Complex64};
pub use crate::complex::octonion_number::{Octonion, Octonion32, Octonion64};
pub use crate::complex::quaternion_number::{Quaternion, Quaternion32, Quaternion64};

// Dual number type (forward-mode automatic differentiation; the differentiating *number*).
// The differentiation/integration *operators* live in `deep_causality_calculus`.
pub use crate::dual::dual_number::Dual;

// Float number types
pub use crate::float::Float;
pub use crate::float_106::Float106;

// Float option number type
pub use crate::float_option::FloatOption;

// Integer types
pub use crate::integer::{Integer, SignedInt, UnsignedInt};

// Isomorphism traits
pub use crate::iso::{AlgebraIso, DivisionAlgebraIso, FieldIso, GroupIso, RingIso};

// General numeric traits
pub use crate::num::Num;
pub use crate::num::identity::one::{ConstOne, One};
pub use crate::num::identity::zero::{ConstZero, Zero};
pub use crate::num::ops::num_ops::*;
