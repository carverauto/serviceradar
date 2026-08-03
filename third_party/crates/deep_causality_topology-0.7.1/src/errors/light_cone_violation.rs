/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Error variants produced by the Lorentzian construction path on
//! `CubicalReggeGeometry<D, R, Lorentzian>` — Phase R5.
//!
//! Two failure modes are tracked:
//!
//! - **`AllSpacelike`** (R5.2) — the caller asked for a Lorentzian signature
//!   but supplied an all-false `timelike_axes` pattern, which has no timelike
//!   axis and is degenerate as a Lorentzian metric.
//! - **`CellSignature { cell_id, eigenvalues }`** (R5.5) — the per-cube
//!   Sylvester-criterion check rejected a top D-cube whose local metric
//!   tensor does not have the required Lorentzian signature `(1 timelike,
//!   D−1 spacelike)`.

use crate::traits::neighborhood::CellId;
use core::fmt;
use deep_causality_algebra::RealField;

/// Failure mode of the Lorentzian constructor on `CubicalReggeGeometry`.
#[derive(Debug, Clone, PartialEq)]
pub enum LightConeViolation<R: RealField> {
    /// All-spacelike `timelike_axes` pattern passed to a Lorentzian
    /// constructor. A Lorentzian signature requires at least one timelike
    /// axis by definition.
    AllSpacelike,

    /// Per-cube signature check (Sylvester's criterion) rejected a top
    /// D-cube. Phase R5.5 populates this variant; until then no constructor
    /// produces it.
    CellSignature {
        cell_id: CellId,
        eigenvalues: Vec<R>,
    },
}

impl<R: RealField + fmt::Debug> fmt::Display for LightConeViolation<R> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AllSpacelike => write!(
                f,
                "Lorentzian signature requires at least one timelike axis; \
                 all-false `timelike_axes` pattern is degenerate."
            ),
            Self::CellSignature {
                cell_id,
                eigenvalues,
            } => write!(
                f,
                "Light-cone violation at cell {cell_id:?}: local metric tensor \
                 has eigenvalues {eigenvalues:?}; expected exactly one negative \
                 eigenvalue (Lorentzian signature)."
            ),
        }
    }
}

impl<R: RealField + fmt::Debug> std::error::Error for LightConeViolation<R> {}
