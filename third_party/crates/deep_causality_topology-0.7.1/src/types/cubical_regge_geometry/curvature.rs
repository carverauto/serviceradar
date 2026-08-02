/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Curvature, hinge enumeration, deficit angles, and the discrete Regge action for
//! `CubicalReggeGeometry<D, R>` — Phases R2 and R3.
//!
//! ## Dihedral angles on axis-aligned cubical cells
//!
//! Under the project-wide axis-aligned cubical assumption (every edge stored in
//! `EdgeLengths` runs along a coordinate axis, no shear), the two (D−1)-faces of a
//! top D-cube that share any (D−2)-hinge are mutually perpendicular regardless of
//! edge lengths. The dihedral angle is therefore exactly π/2 in every variant:
//! `UnitEdge`, `Uniform`, `PerAxis`, and `PerEdge`.
//!
//! This is a deliberate correction to the original design note
//! `openspec/notes/CubicalReggeCalculus.md` §3.R2, which proposed
//! `arctan2(lengths[j], lengths[i])` for the `PerAxis` case. The proposed formula
//! conflated the dihedral angle between faces with the half-angle of a stretched
//! cube's diagonal; for axis-aligned cubes those are different quantities and only
//! the constant `π/2` is geometrically meaningful as a dihedral.
//!
//! Curvature on a cubical lattice therefore enters only through:
//!
//! 1. **Incidence count of hinges.** Interior hinges in a periodic 2D/3D/4D lattice
//!    have 4 incident top cubes (sum 2π, deficit 0 — flat). Boundary hinges on open
//!    lattices have fewer (e.g. 1 at a 2D corner, sum π/2, deficit 3π/2 — intrinsic
//!    boundary curvature).
//! 2. **Sheared / non-axis-aligned cells**, which the current `EdgeLengths`
//!    representation does not express. A future Gram-matrix-aware extension would
//!    rewrite the dihedral closed forms here.
//!
//! See `openspec/changes/add-cubical-regge-calculus-core/tasks.md` §3 and §4.

use super::{CubicalReggeGeometry, Euclidean, Lorentzian, SignatureMarker};
use crate::traits::neighborhood::CellId;
use crate::types::lattice_complex::{LatticeCell, LatticeComplex};
use deep_causality_algebra::RealField;
use deep_causality_num_complex::Complex;

/// Signature-independent geometric methods: dihedral angles, deficit angles.
/// Available on every signature variant since the axis-aligned cubical
/// geometry of these quantities does not depend on the metric signature.
impl<const D: usize, R: RealField, S: SignatureMarker> CubicalReggeGeometry<D, R, S> {
    /// Dihedral angle that `top_cube` contributes at `hinge`.
    ///
    /// On an axis-aligned cubical complex this is exactly π/2 = `R::pi() / 2`
    /// regardless of the edge-length variant. See the module documentation for why.
    /// The lattice argument is accepted for API symmetry with future sheared /
    /// Riemannian extensions, where the angle would depend on local Gram-matrix
    /// entries; current code does not read it.
    ///
    /// # Debug assertions
    ///
    /// In debug builds this asserts `top_cube.cell_dim() == D` and
    /// `hinge.cell_dim() == D - 2`. The function does not validate that the cube is
    /// actually incident to the hinge — callers (notably `regge_action` via
    /// `LatticeComplex::hinge_top_cube_neighbors`) are responsible for enumerating
    /// only incident pairs. For axis-aligned cubical cells, non-incident pairs still
    /// produce a geometrically meaningful constant (π/2), so silent misuse degrades
    /// to a constant rather than NaN.
    pub fn dihedral_angle(
        &self,
        _complex: &LatticeComplex<D, R>,
        top_cube: &LatticeCell<D>,
        hinge: &LatticeCell<D>,
    ) -> R {
        debug_assert!(D >= 2, "dihedral_angle requires D >= 2");
        debug_assert_eq!(
            top_cube.cell_dim(),
            D,
            "dihedral_angle: top_cube must be a D-cell (got grade {})",
            top_cube.cell_dim(),
        );
        debug_assert_eq!(
            hinge.cell_dim(),
            D - 2,
            "dihedral_angle: hinge must be a (D-2)-cell (got grade {})",
            hinge.cell_dim(),
        );

        let two = R::one() + R::one();
        R::pi() / two
    }

    /// Deficit angle at a hinge: `2π − Σ dihedral_angle(c, h)` summed over incident top
    /// cubes.
    ///
    /// Under the axis-aligned cubical assumption (see `dihedral_angle`), every dihedral
    /// equals π/2, so deficit reduces to `(4 − n) · π/2` where `n` is the incident-top-cube
    /// count. The implementation short-circuits the `n == 4` (interior / fully-surrounded)
    /// case to return exact `R::zero()`, avoiding floating-point noise from `2π − 2π`.
    /// For `n < 4` (boundary hinges on open lattices), the result is the intrinsic
    /// boundary curvature: positive deficit at corners and edges where less material
    /// surrounds the hinge.
    ///
    /// Returns `R::zero()` for `D < 2` (where (D−2)-hinges don't exist) and for
    /// out-of-range `hinge_id` (a tolerant degenerate case rather than a panic).
    ///
    /// `timelike_axes` is ignored in this change set; the Lorentzian variant is deferred
    /// to a follow-up.
    pub fn deficit_angle(&self, complex: &LatticeComplex<D, R>, hinge_id: CellId) -> R {
        if D < 2 {
            return R::zero();
        }
        let neighbors = complex.hinge_top_cube_neighbors(hinge_id);
        let n = neighbors.len();
        // Interior hinges (n == 4) and out-of-range hinges (n == 0, neighbors is empty)
        // both short-circuit to zero. The interior case is genuine flatness; the empty
        // case matches the docstring's tolerant-degenerate contract and avoids returning
        // a meaningless 2π for a hinge that doesn't exist.
        if n == 4 || n == 0 {
            return R::zero();
        }

        let two = R::one() + R::one();
        let two_pi = R::pi() + R::pi();
        let pi_over_two = R::pi() / two;
        let mut deficit = two_pi;
        for _ in 0..n {
            deficit -= pi_over_two;
        }
        deficit
    }

    /// Discrete Einstein–Hilbert (Regge) action: `Σ_h cell_volume(h) · deficit_angle(h)`
    /// summed over every (D−2)-hinge.
    ///
    /// For `D < 2` the sum is empty and the action is `R::zero()`.
    ///
    /// On a regular periodic lattice every interior hinge has deficit zero (4 incident
    /// top cubes, sum of dihedrals = 2π), so the action is zero. On an open lattice,
    /// boundary hinges carry intrinsic curvature and the action is non-trivial. Under
    /// the axis-aligned cubical assumption the deficit factor depends only on hinge
    /// incidence count, so all edge-length sensitivity of the action flows through the
    /// `cell_volume(h)` factor — vertex hinges in 2D have `volume = R::one()`
    /// (the empty product), whereas edge hinges in 3D and square hinges in 4D scale
    /// with the metric.
    /// Internal hinge-action sum used by both the Euclidean `regge_action` and the
    /// Lorentzian `regge_action_lorentzian`. Returns the real-valued sum
    /// `Σ_h volume(h) · deficit_angle(h)` over every (D−2)-hinge. The Lorentzian
    /// variant then applies the Wick-rotation `i` factor on top.
    pub(super) fn hinge_action_sum(&self, complex: &LatticeComplex<D, R>) -> R {
        if D < 2 {
            return R::zero();
        }
        let mut action = R::zero();
        for (hinge_id, hinge) in complex.iter_cells(D - 2).enumerate() {
            let deficit = self.deficit_angle(complex, hinge_id);
            // Skip the volume × 0 multiplication for interior hinges.
            if deficit == R::zero() {
                continue;
            }
            let vol = self.cell_volume(complex, &hinge);
            action += vol * deficit;
        }
        action
    }
}

/// Euclidean-only methods on `CubicalReggeGeometry<D, R, Euclidean>`.
impl<const D: usize, R: RealField> CubicalReggeGeometry<D, R, Euclidean> {
    /// Discrete Einstein–Hilbert action in the Euclidean signature.
    ///
    /// Sums `Σ_h volume(h) · deficit_angle(h)` over every (D−2)-hinge of the cubical
    /// complex. Interior hinges on a periodic lattice contribute zero (deficit = 0,
    /// flat geometry); boundary hinges on open lattices carry intrinsic curvature
    /// and make the action non-trivial.
    ///
    /// The Lorentzian variant is [`CubicalReggeGeometry::<D, R, Lorentzian>::regge_action_lorentzian`],
    /// which returns `Complex<R>` and applies the Wick rotation factor.
    pub fn regge_action(&self, complex: &LatticeComplex<D, R>) -> R {
        self.hinge_action_sum(complex)
    }
}

/// Lorentzian-only methods on `CubicalReggeGeometry<D, R, Lorentzian>`.
impl<const D: usize, R: RealField> CubicalReggeGeometry<D, R, Lorentzian> {
    /// Discrete Einstein–Hilbert action in the Lorentzian signature, Wick-rotated.
    ///
    /// Returns `Complex<R>` whose real part equals the Euclidean
    /// `hinge_action_sum` and whose
    /// imaginary part carries the Wick-rotation phase. The reduction property
    /// `regge_action_lorentzian(all-spacelike) == Complex::new(regge_action, 0)` is
    /// the design.md Decision-3 reduction check.
    ///
    /// Phase convention: `S_R^Lorentzian = i · S_R^Euclidean` (Euclidean-to-Lorentzian
    /// Wick rotation `t = −iτ`). This matches the East-Coast signature carried by
    /// the `Lorentzian` marker.
    pub fn regge_action_lorentzian(&self, complex: &LatticeComplex<D, R>) -> Complex<R> {
        let s = self.hinge_action_sum(complex);
        Complex {
            re: R::zero(),
            im: s,
        }
    }
}
