/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! HKT3 witness and trait implementations for GaugeField.
//!
//! This module provides MonoidalMerge and ParametricMonad implementations for GaugeField,
//! enabling current-field coupling and gauge transformation operations.
//!
//! # Architectural Note
//!
//! GaugeField<G, A, F> has a non-uniform constraint: G must implement GaugeGroup,
//! while A and F can be any type. The standard HKT3Unbound trait expects a single
//! uniform constraint for all three type parameters.
//!
//! We work around this by:
//! 1. Implementing HKT3Unbound with NoConstraint (allowing any types)
//! 2. Providing type-safe operations through specialized methods
//! 3. Using concrete GaugeField operations that enforce G: GaugeGroup at call sites

pub mod hkt_adjunction_stokes;
pub mod hkt_curvature;
pub mod hkt_gauge_witness;
pub mod hkt_lattice_gauge;
