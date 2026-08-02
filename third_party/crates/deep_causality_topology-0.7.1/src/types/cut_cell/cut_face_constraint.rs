/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! A single aperture-resolved immersed-wall constraint row.

use deep_causality_algebra::RealField;
/// Which wall condition a [`CutFaceConstraint`] row enforces.
///
/// The split lets the physics layer ablate the **no-penetration** row independently of the
/// **tangential no-slip** rows (the open question of whether the cut Hodge star already carries
/// no-penetration via its flux down-weighting — design Decision 2 / tasks.md 4.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CutConstraintKind {
    /// `n̂ · u_face = 0`: zero flux normal to the wetted cut face (the fragment outward normal).
    NoPenetration,
    /// `t̂ · u_face = 0`: zero tangential velocity relative to a static body (one row per tangent
    /// of the local wall frame).
    Tangential,
}

/// One sparse linear constraint on the edge 1-cochain, derived from a `Cut` cell's geometry:
/// `Σ (weight · u_edge) = target`.
///
/// Each row is the wall condition evaluated at the wetted cut face of a single cut cell, expressed
/// as an aperture-weighted reconstruction of the cell's velocity contracted with one direction of
/// the local wall frame. The binary staircase pin (`u_edge = 0`) is the special case of a
/// single-entry, unit-weight, zero-`target` row, so this type generalises
/// [`crate::CutCellRegistry::solid_incident_edges`] (design Decision 2, Lever A).
///
/// The rows are *data*: the topology layer derives them from geometry; the constrained Leray
/// projector consumes them (`Cᵀu = b`). A non-zero `target` is the hook for a prescribed
/// (moving-body) wall velocity, kept `0` for the static-body scope of this change.
#[derive(Debug, Clone, PartialEq)]
pub struct CutFaceConstraint<R: RealField> {
    entries: Vec<(usize, R)>,
    target: R,
    row_weight: R,
    kind: CutConstraintKind,
}

impl<R: RealField> CutFaceConstraint<R> {
    /// Build a constraint row from its sparse `(edge_index, weight)` entries, its right-hand-side
    /// `target` value, the `row_weight` measure (the fragment area, for KKT row scaling), and its
    /// [`CutConstraintKind`].
    pub fn new(
        entries: Vec<(usize, R)>,
        target: R,
        row_weight: R,
        kind: CutConstraintKind,
    ) -> Self {
        Self {
            entries,
            target,
            row_weight,
            kind,
        }
    }

    /// The sparse `(edge_index, weight)` entries of the row.
    pub fn entries(&self) -> &[(usize, R)] {
        &self.entries
    }

    /// The right-hand-side value `b` of the row (`0` for a static body).
    pub fn target(&self) -> R {
        self.target
    }

    /// The row measure (fragment area), used to scale the constraint in the KKT projection.
    pub fn row_weight(&self) -> R {
        self.row_weight
    }

    /// Whether this is a no-penetration or a tangential no-slip row.
    pub fn kind(&self) -> CutConstraintKind {
        self.kind
    }
}
