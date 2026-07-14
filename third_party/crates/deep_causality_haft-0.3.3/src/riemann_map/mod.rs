/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT4Unbound, Satisfies};

/// The `RiemannMap` trait models high-arity geometric interactions, specifically the
/// Riemann Curvature Tensor and Scattering Matrices.
///
/// # Category Theory
/// This corresponds to a **Multilinear Map** in a Tensor Category.
/// Specifically, the Curvature Tensor is a map $R: V \otimes V \otimes V \to V$.
///
/// # Mathematical Definition
/// The Riemann Curvature Tensor $R$ is defined in terms of the covariant derivative $\nabla$:
/// $$ R(u, v)w = \nabla_u \nabla_v w - \nabla_v \nabla_u w - \nabla_{[u, v]} w $$
/// It measures the non-commutativity of parallel transport around a loop defined by $u$ and $v$.
///
/// # Use Cases
/// *   **General Relativity**: Calculating gravity as spacetime curvature.
/// *   **Particle Physics**: Scattering matrices (S-Matrix) taking 2 inputs and producing 2 outputs.
/// *   **Differential Geometry**: Measuring the holonomy of a connection.
pub trait RiemannMap<P: HKT4Unbound> {
    /// The Curvature Operator: $R(u, v)w \to D$
    /// Consumes two directions ($u, v$) and a vector ($w$) to measure curvature ($D$).
    fn curvature<A, B, C, D>(tensor: P::Type<A, B, C, D>, u: A, v: B, w: C) -> D
    where
        A: Satisfies<P::Constraint>,
        B: Satisfies<P::Constraint>,
        C: Satisfies<P::Constraint>,
        D: Satisfies<P::Constraint>;

    /// The Scattering Matrix: $(A, B) \to (C, D)$
    /// Models an interaction where two particles collide and produce two new states.
    fn scatter<A, B, C, D>(interaction: P::Type<A, B, C, D>, in_1: A, in_2: B) -> (C, D)
    where
        A: Satisfies<P::Constraint>,
        B: Satisfies<P::Constraint>,
        C: Satisfies<P::Constraint>,
        D: Satisfies<P::Constraint>;
}
