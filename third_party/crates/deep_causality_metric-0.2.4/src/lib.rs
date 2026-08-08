/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # deep_causality_metric
//!
//! Metric signature types and sign conventions for Clifford algebras and physics.
//!
//! This crate provides a foundational set of types for working with metric signatures
//! in Clifford algebras Cl(p, q, r), Riemannian geometry, and physics.
//!
//! ## Key Features
//!
//! - **Single Source of Truth**: Consolidates all metric signature logic
//! - **Zero Dependencies**: Serves as a foundational leaf crate
//! - **Type-Safe Conventions**: Compile-time enforcement of physics sign conventions
//! - **Cross-Crate Integration**: Enables consistent metric handling
//!
//! ## Core Types
//!
//! - [`Metric`]: The core enum representing Clifford algebra signatures
//! - [`MetricError`]: Error type for metric operations
//! - [`LorentzianMetric`]: Trait for convention-specific wrappers
//! - [`EastCoastMetric`]: Wrapper for (-+++) convention (GR)
//! - [`WestCoastMetric`]: Wrapper for (+---) convention (Particle Physics)
//!
//! ## Sign Conventions
//!
//! | Convention | Signature | g_{μν} | Used By |
//! |------------|-----------|--------|---------|
//! | East Coast | (-+++) | diag(-1,1,1,1) | MTW, GR textbooks |
//! | West Coast | (+---) | diag(1,-1,-1,-1) | Weinberg, Particle physics |
//!
//! ## Example
//!
//! ```
//! use deep_causality_metric::{
//!     Metric, EastCoastMetric, WestCoastMetric, LorentzianMetric,
//! };
//!
//! // Create a standard 4D Minkowski metric in West Coast convention
//! let west = Metric::Minkowski(4);
//! assert_eq!(west.sign_of_sq(0), 1);  // time is +1
//! assert_eq!(west.sign_of_sq(1), -1); // space is -1
//!
//! // Use type-safe wrappers for convention enforcement
//! let east = EastCoastMetric::minkowski_4d();
//! assert_eq!(east.time_sign(), -1);
//! assert_eq!(east.space_sign(), 1);
//!
//! let west = WestCoastMetric::minkowski_4d();
//! assert_eq!(west.time_sign(), 1);
//! assert_eq!(west.space_sign(), -1);
//! ```

#![cfg_attr(not(feature = "std"), no_std)]
#[cfg(feature = "alloc")]
extern crate alloc;
extern crate core;

mod conventions;
mod errors;
mod ops;
mod types;

// Errors
pub use crate::errors::MetricError;

// Types
pub use crate::types::Metric;

// Conventions trait
pub use crate::conventions::LorentzianMetric;

// Convention newtypes
pub use crate::conventions::{EastCoastMetric, WestCoastMetric};

// Type aliases
pub use crate::conventions::{ParticleMetric, PhysicsMetric, RelativityMetric};

// Constants
pub use crate::conventions::{MINKOWSKI_4D, PARTICLE_MINKOWSKI_4D, RELATIVITY_MINKOWSKI_4D};

// Conversion operations
pub use crate::ops::{detect_convention, east_to_west, is_lorentzian, west_to_east};
