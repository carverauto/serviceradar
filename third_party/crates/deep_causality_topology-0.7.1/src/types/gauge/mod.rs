/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Gauge Field type for unified gauge theory representation.
//!
//! A gauge field combines a base manifold, metric signature, connection (potential),
//! and field strength (curvature) under a specified gauge group symmetry.
//!
//! # Example
//!
//! ```ignore
//! use deep_causality_topology::{GaugeField, U1, Lorentz, Manifold};
//! use deep_causality_tensor::CausalTensor;
//!
//! // Create an electromagnetic (QED) gauge field with f64 precision
//! let em: GaugeField<U1, f64, f64, f64> = GaugeField::with_default_metric(
//!     spacetime,
//!     potential,
//!     field_strength,
//! );
//!
//! // Create a high-precision EM field with DoubleFloat
//! let em_double: GaugeField<U1, DoubleFloat, DoubleFloat, DoubleFloat> = ...;
//!
//! // Create a gravitational (GR) gauge field
//! let gravity: GaugeField<Lorentz, f64, f64, f64> = GaugeField::with_default_metric(
//!     spacetime,
//!     christoffel,
//!     riemann_tensor,
//! );
//! ```

pub mod gauge_field;
pub mod gauge_field_lattice;
pub mod gauge_groups;
pub mod link_variable;

pub use gauge_field::GaugeField;
pub use gauge_field_lattice::LatticeGaugeField;
pub use link_variable::LinkVariable;
