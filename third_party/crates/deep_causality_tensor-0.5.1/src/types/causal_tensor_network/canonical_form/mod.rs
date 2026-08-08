/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Which orthogonality sweep (if any) a [`CausalTensorTrain`](crate::CausalTensorTrain) currently
/// carries. Tracking it lets `round`, `inner`, and the sweep algorithms skip redundant
/// re-canonicalization.
///
/// Indices are core positions in `0..order`:
/// - `LeftAt(k)`  — cores `0..=k` are left-orthonormal.
/// - `RightAt(k)` — cores `k..` are right-orthonormal.
/// - `Mixed(k)`   — the orthogonality centre is on core `k`: cores `0..k` are left-orthonormal and
///   cores `k+1..` are right-orthonormal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CanonicalForm {
    /// No orthogonality structure is known to hold.
    #[default]
    None,
    /// Cores `0..=k` are left-orthonormal.
    LeftAt(usize),
    /// Cores `k..` are right-orthonormal.
    RightAt(usize),
    /// The orthogonality centre is on core `k`.
    Mixed(usize),
}
