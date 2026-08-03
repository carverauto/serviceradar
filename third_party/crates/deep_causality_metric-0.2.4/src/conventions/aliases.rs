/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Domain-specific type aliases for common physics conventions.
//!
//! These aliases provide semantic meaning when working with different physics domains:
//! - **General Relativity** uses East Coast (-+++) convention
//! - **Particle Physics** uses West Coast (+---) convention

use crate::conventions::{EastCoastMetric, WestCoastMetric};

/// For General Relativity modules: East Coast (-+++)
///
/// This is the convention used by Misner-Thorne-Wheeler (MTW) and most
/// GR textbooks. Timelike vectors have negative norm: g(u,u) < 0.
pub type RelativityMetric = EastCoastMetric;

/// Standard 4D Minkowski spacetime for General Relativity.
pub const RELATIVITY_MINKOWSKI_4D: RelativityMetric = EastCoastMetric::MINKOWSKI_4D;

/// For Particle Physics modules: West Coast (+---)
///
/// This is the convention used by Weinberg and most particle physics literature.
/// Timelike vectors have positive norm: g(u,u) > 0.
pub type ParticleMetric = WestCoastMetric;

/// Standard 4D Minkowski spacetime for Particle Physics.
pub const PARTICLE_MINKOWSKI_4D: ParticleMetric = WestCoastMetric::MINKOWSKI_4D;

/// Default physics metric (configurable): East Coast.
///
/// This crate defaults to the East Coast (GR) convention.
/// Use `ParticleMetric` explicitly when working with particle physics.
pub type PhysicsMetric = RelativityMetric;

/// Default 4D Minkowski spacetime (East Coast convention).
pub const MINKOWSKI_4D: PhysicsMetric = RELATIVITY_MINKOWSKI_4D;
