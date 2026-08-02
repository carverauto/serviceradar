/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Cubical Regge geometry — the cubical analogue of `ReggeGeometry<T>`.
//!
//! `CubicalReggeGeometry<D>` encodes the discrete geometric data on a D-dimensional
//! cubical (lattice) complex. It is the `Metric` associated type chosen by the
//! `ChainComplex` impl on `LatticeComplex<D>` and pairs structurally with the simplicial
//! `ReggeGeometry<T>`: where Regge calculus stores edge lengths on a simplicial complex
//! and derives curvature via deficit angles around codimension-2 hinges, the cubical
//! Regge formulation does the same on a hypercubic lattice.
//!
//! ## Naming
//!
//! "Cubical Regge calculus" / "hypercubic Regge calculus" appears in the lattice quantum
//! gravity literature as the natural extension of Regge's original simplicial construction
//! to cubical cells. The type name follows this established (if minor) usage and parallels
//! `ReggeGeometry<T>` in the simplicial path.
//!
//! ## Edge-length representation
//!
//! Cubical complexes admit three useful levels of metric uniformity:
//!
//! | Level | Storage | Use case |
//! |-------|---------|----------|
//! | Unit edge | nothing | Standard voxel grids, the Stage C / issue #487 fast path. |
//! | Uniform | `f64` | Isotropic lattice with a single spacing `a`. The lattice-spacing case in physics. |
//! | Per-axis | `[f64; D]` | Anisotropic but axis-aligned lattices. |
//! | Per-edge | `Vec<f64>` | Fully general, edge-by-edge length assignment. Required for curved cubical metrics. |
//!
//! The four levels are unioned in the private `EdgeLengths<D>` enum. Constructors exist
//! for each level so callers state intent at construction time and the type-level uniformity
//! information is preserved for downstream optimization.
//!
//! ## Shipped (Phases R1–R3 of `add-cubical-regge-calculus-core`)
//!
//! The geometric core of cubical Regge calculus is implemented across two sibling submodules:
//!
//! - `volumes` — R1: `cell_volume(complex, cell)` and `top_cell_volume(complex, cell)`,
//!   dispatching on the four `EdgeLengths` variants under the axis-aligned cubical assumption.
//! - `curvature` — R2 + R3: `dihedral_angle(complex, top_cube, hinge)` (returns π/2
//!   uniformly under axis-alignment), `deficit_angle(complex, hinge_id)` (depends only on
//!   hinge incidence count), and `regge_action(complex)` (sums `cell_volume(h) ·
//!   deficit_angle(h)` over every (D−2)-hinge).
//!
//! Curvature on an axis-aligned cubical lattice arises from two sources:
//!
//! 1. **Hinge incidence count.** Interior hinges on a periodic lattice have 4 incident
//!    top cubes, sum dihedrals = 2π, deficit = 0 (flat). Boundary hinges on open
//!    lattices have fewer incident cubes (e.g. 1 at a 2D corner, deficit 3π/2 —
//!    intrinsic boundary curvature).
//! 2. **Hinge volumes.** The action's edge-length sensitivity flows through the
//!    `cell_volume(h)` factor — vertex hinges in 2D have volume 1 (empty product),
//!    edge hinges in 3D and square hinges in 4D scale with the metric.
//!
//! ## Forward-looking scope (deferred to follow-up change sets)
//!
//! The following derived quantities are designed-for but not yet implemented; the struct's
//! current fields and submodule layout are sufficient inputs for all of them:
//!
//! - **`hodge_star_matrix(k)`** — Hodge ⋆ on k-forms, diagonal under axis-alignment.
//!   Deferred to `add-cubical-regge-calculus-analytical` (R4). The keystone that promotes
//!   `manifold/differential/{hodge,laplacian}.rs` to be generic over `ChainComplex`.
//! - **`metric_at(complex, cell)`** and a type-level Lorentzian marker — local metric
//!   signature, light-cone enforcement. Deferred to R5. Reads the `timelike_axes` field
//!   which is currently stored but ignored by `regge_action` and `deficit_angle`.
//! - **`regge_gradient(complex)`** and `metropolis_update` — action gradient and Markov
//!   chain dynamics. Deferred to R6.
//!
//! See [`openspec/notes/CubicalReggeCalculus.md`](../../../../openspec/notes/CubicalReggeCalculus.md)
//! for the full R1–R6 design note.

pub mod curvature;
pub mod graded;
pub mod gradient;
pub mod has_hodge_star;
pub mod metric_tensor;
pub mod metropolis;
pub mod signature;
mod star_cache;
pub mod volumes;

pub use metropolis::{AcceptReject, RejectReason};
pub use signature::{Euclidean, Lorentzian, SignatureMarker};

use core::marker::PhantomData;
use deep_causality_algebra::RealField;
use deep_causality_metric::Metric;
/// Cubical Regge geometry: discrete metric data on a D-dimensional cubical complex.
///
/// Parallels `ReggeGeometry<R>` for the simplicial case. See the module-level doc for
/// the four supported levels of edge-length uniformity and the forward-looking scope of
/// derived geometric quantities. Parameterised over:
///
/// * `D` — lattice dimension.
/// * `R: RealField` — precision of stored edge lengths (`f32`, `f64`, `Float106`, …).
/// * `S: SignatureMarker = Euclidean` — type-level metric signature
///   ([`Euclidean`] or [`Lorentzian`]). Defaulted to `Euclidean` so R1–R3 / R4
///   call sites continue to compile unchanged after the R5 promotion.
///
/// The `Lorentzian` variant is constructed via [`CubicalReggeGeometry::with_timelike_axes`]
/// and carries a `timelike_axes` pattern marking which axes are timelike. The
/// `Euclidean` default constructors (`unit`, `uniform`, `per_axis`, `from_edge_lengths`)
/// always produce all-spacelike geometries.
#[derive(Debug, Clone, PartialEq)]
pub struct CubicalReggeGeometry<const D: usize, R: RealField, S: SignatureMarker = Euclidean> {
    pub(super) edge_lengths: EdgeLengths<D, R>,
    /// Per-axis flag marking timelike axes for Lorentzian / Minkowski lattices.
    /// On `S = Euclidean` this is always `None`. On `S = Lorentzian` it carries
    /// the timelike-axis pattern set at construction time; at least one entry
    /// is guaranteed `true` by the Lorentzian constructor's validation.
    pub(super) timelike_axes: Option<[bool; D]>,
    pub(super) _signature: PhantomData<S>,
    /// Optional cut-cell overlay (CFD Stage 4). `None` is the ordinary
    /// uncut geometry — every star read uses the integer `2^{-b}` wall clip
    /// and the path is byte-identical to before cut cells existed. `Some`
    /// makes every Hodge-star read (and therefore the compiled stencils, the
    /// Leray projection, the codifferential — everything that routes through
    /// ⋆) use the continuous wetted fraction instead, so an immersed body is
    /// seen transparently by the whole operator stack. Attached via
    /// [`CubicalReggeGeometry::with_cut_cells`] before the manifold is built;
    /// immutable thereafter (Stage-4 Context).
    pub(super) cut_registry: Option<crate::types::cut_cell::CutCellRegistry<D, R>>,
    /// Lazy per-grade memo of the diagonal Hodge ⋆ matrices (see
    /// [`star_cache`]). Ignored for equality; cloned warm; invalidated on
    /// geometry mutation.
    pub(in crate::types::cubical_regge_geometry) star_cache: star_cache::StarCache<D, R>,
}

/// Module-private union of the four edge-length representations. `pub(super)` so sibling
/// submodules (`volumes`, `curvature`) can match on the variant for closed-form fast paths;
/// crate-level callers still go through the public constructors and the `axis_length` /
/// `edge_length` getters.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum EdgeLengths<const D: usize, R: RealField> {
    /// Every edge has length `1.0`. The Stage C / voxel-grid fast path. Carries no `R`-typed
    /// storage; the `R: RealField` parameter exists only to satisfy the type-level binding.
    UnitEdge,
    /// Every edge has length `length`. Isotropic lattice with a single spacing.
    Uniform { length: R },
    /// Edges within each axis are uniform; lengths may differ between axes.
    PerAxis { lengths: [R; D] },
    /// Fully general per-edge lengths, indexed by edge cell_id in the lattice's
    /// `iter_cells(1)` ordering. Required for curved cubical metrics.
    PerEdge { lengths: Vec<R> },
}

impl<const D: usize, R: RealField> CubicalReggeGeometry<D, R, Euclidean> {
    // -- Euclidean constructors ------------------------------------------------------

    /// The unit-edge cubical Regge geometry: every edge has length `1.0`.
    ///
    /// The canonical metric for voxel grids and the Stage C / issue #487 fast path.
    /// Returns `R::one()` for uniform / axis / edge queries.
    pub fn unit() -> Self {
        Self {
            edge_lengths: EdgeLengths::UnitEdge,
            timelike_axes: None,
            _signature: PhantomData,
            cut_registry: None,
            star_cache: star_cache::StarCache::new(),
        }
    }

    /// Isotropic lattice with a single spacing `length` on every edge.
    ///
    /// Equivalent to the lattice-spacing scalar `a` used throughout lattice gauge theory.
    pub fn uniform(length: R) -> Self {
        Self {
            edge_lengths: EdgeLengths::Uniform { length },
            timelike_axes: None,
            _signature: PhantomData,
            cut_registry: None,
            star_cache: star_cache::StarCache::new(),
        }
    }

    /// Anisotropic axis-aligned lattice: each axis has its own uniform edge length.
    ///
    /// All edges in dimension `i` have length `lengths[i]`. Useful for stretched lattices,
    /// asymmetric voxel grids, and anisotropic-coupling lattice gauge studies.
    pub fn per_axis(lengths: [R; D]) -> Self {
        Self {
            edge_lengths: EdgeLengths::PerAxis { lengths },
            timelike_axes: None,
            _signature: PhantomData,
            cut_registry: None,
            star_cache: star_cache::StarCache::new(),
        }
    }

    /// Fully general per-edge length assignment.
    ///
    /// `lengths[i]` is the length of the i-th edge in the lattice complex's
    /// `iter_cells(1)` enumeration order. Required for curved cubical metrics
    /// (non-flat lattices, dynamic spacetimes, deficit-angle-bearing geometries).
    pub fn from_edge_lengths(lengths: Vec<R>) -> Self {
        Self {
            edge_lengths: EdgeLengths::PerEdge { lengths },
            timelike_axes: None,
            _signature: PhantomData,
            cut_registry: None,
            star_cache: star_cache::StarCache::new(),
        }
    }

    /// Promote this Euclidean geometry to a [`Lorentzian`]-marked geometry with the
    /// given `timelike` axis pattern.
    ///
    /// This is the *only* entry point to the `Lorentzian` signature variant. The
    /// type system tracks the signature distinction from this point on:
    /// Lorentzian-only operations (Wick-rotated action, signed Hodge ⋆, light-cone
    /// enforcement) are gated on the resulting `CubicalReggeGeometry<D, R, Lorentzian>`
    /// at the impl-block level.
    ///
    /// # Signature validation (R5.5)
    ///
    /// Performs the Sylvester's-criterion check for an axis-aligned Lorentzian
    /// metric: the timelike-axis count must equal exactly 1 (one negative
    /// eigenvalue, `D−1` positive eigenvalues — the East-Coast convention).
    /// Other configurations are rejected at construction:
    ///
    /// - **0 timelike axes** ⇒ [`crate::LightConeViolation::AllSpacelike`]. Degenerate
    ///   Lorentzian metric with no timelike axis.
    /// - **≥ 2 timelike axes** ⇒ [`crate::LightConeViolation::CellSignature`] with the
    ///   synthesized per-axis diagonal sign pattern as `eigenvalues`. The
    ///   `Lorentzian` marker is reserved for genuine `(D−1, 1)` signatures per
    ///   `design.md` Decision 9; split-signature `(p, q)` with `q ≥ 2` lives in
    ///   the deferred-categorical-coherence track (out of scope here).
    pub fn with_timelike_axes(
        self,
        timelike: [bool; D],
    ) -> Result<CubicalReggeGeometry<D, R, Lorentzian>, crate::LightConeViolation<R>> {
        let timelike_count = timelike.iter().filter(|&&t| t).count();
        if timelike_count == 0 {
            return Err(crate::LightConeViolation::AllSpacelike);
        }
        if timelike_count > 1 {
            // Synthesize the diagonal-sign pattern as the eigenvalue spectrum.
            // For axis-aligned cubical, the metric signature is uniform across
            // cells; one violating cell stands for all of them. `cell_id = 0`
            // is used as a sentinel — the failure is global, not local.
            let eigenvalues = timelike
                .iter()
                .map(|&t| if t { -R::one() } else { R::one() })
                .collect();
            return Err(crate::LightConeViolation::CellSignature {
                cell_id: 0,
                eigenvalues,
            });
        }
        Ok(CubicalReggeGeometry {
            edge_lengths: self.edge_lengths,
            timelike_axes: Some(timelike),
            _signature: PhantomData,
            cut_registry: self.cut_registry,
            star_cache: star_cache::StarCache::new(),
        })
    }
}

impl<const D: usize, R: RealField, S: SignatureMarker> CubicalReggeGeometry<D, R, S> {
    /// Attach a cut-cell overlay (CFD Stage 4). Every subsequent Hodge-star read uses the
    /// registry's continuous wetted fraction in place of the integer `2^{-b}` wall clip, so
    /// the compiled stencils, the Leray projection and the codifferential all see the immersed
    /// body transparently. An **empty** registry leaves the star byte-identical to the uncut
    /// geometry (the Stage-3 equivalence), so attaching one is safe by construction. Resets the
    /// star memo so no pre-cut matrix is served. Attach before building the manifold; immutable
    /// thereafter (Stage-4 Context).
    pub fn with_cut_cells(
        mut self,
        registry: crate::types::cut_cell::CutCellRegistry<D, R>,
    ) -> Self {
        self.cut_registry = Some(registry);
        self.star_cache = star_cache::StarCache::new();
        self
    }

    /// The attached cut-cell registry, if any.
    pub fn cut_registry(&self) -> Option<&crate::types::cut_cell::CutCellRegistry<D, R>> {
        self.cut_registry.as_ref()
    }

    // -- Getters (available on every signature) --------------------------------------

    /// `true` iff this geometry is the unit-edge case (every edge has length `1.0`).
    pub fn is_unit_edge(&self) -> bool {
        matches!(self.edge_lengths, EdgeLengths::UnitEdge)
    }

    /// `true` iff every edge has the same length (either UnitEdge or Uniform).
    pub fn is_isotropic(&self) -> bool {
        matches!(
            self.edge_lengths,
            EdgeLengths::UnitEdge | EdgeLengths::Uniform { .. }
        )
    }

    /// `true` iff edges within each axis are uniform (UnitEdge, Uniform, or PerAxis).
    pub fn is_axis_aligned(&self) -> bool {
        !matches!(self.edge_lengths, EdgeLengths::PerEdge { .. })
    }

    /// The uniform edge length, if every edge has the same length.
    /// `Some(R::one())` for UnitEdge, `Some(length)` for Uniform, `None` otherwise.
    pub fn uniform_length(&self) -> Option<R> {
        match &self.edge_lengths {
            EdgeLengths::UnitEdge => Some(R::one()),
            EdgeLengths::Uniform { length } => Some(*length),
            _ => None,
        }
    }

    /// Per-axis uniform lengths, if the geometry is axis-aligned.
    /// `Some([R::one(); D])` for UnitEdge, `Some([length; D])` for Uniform, `Some(lengths)`
    /// for PerAxis, `None` for PerEdge.
    pub fn axis_lengths(&self) -> Option<[R; D]> {
        match &self.edge_lengths {
            EdgeLengths::UnitEdge => Some([R::one(); D]),
            EdgeLengths::Uniform { length } => Some([*length; D]),
            EdgeLengths::PerAxis { lengths } => Some(*lengths),
            EdgeLengths::PerEdge { .. } => None,
        }
    }

    /// Edge length for an edge along axis `axis`. Returns `None` if `axis >= D` or if the
    /// geometry is per-edge (in which case `edge_length_at(edge_id)` is the right call).
    pub fn axis_length(&self, axis: usize) -> Option<R> {
        if axis >= D {
            return None;
        }
        match &self.edge_lengths {
            EdgeLengths::UnitEdge => Some(R::one()),
            EdgeLengths::Uniform { length } => Some(*length),
            EdgeLengths::PerAxis { lengths } => Some(lengths[axis]),
            EdgeLengths::PerEdge { .. } => None,
        }
    }

    /// Edge length at a specific edge `edge_id` (index in the lattice's `iter_cells(1)`
    /// ordering). Defined for all four representations: returns the uniform value for the
    /// degenerate cases, the per-edge value for the general case. `None` if `edge_id` is
    /// out of range for a per-edge geometry.
    pub fn edge_length_at(&self, edge_id: usize) -> Option<R> {
        match &self.edge_lengths {
            EdgeLengths::UnitEdge => Some(R::one()),
            EdgeLengths::Uniform { length } => Some(*length),
            EdgeLengths::PerAxis { .. } => {
                // For per-axis representation, edge_id alone is not enough — the axis must
                // be supplied separately via `axis_length`. Returning `None` here signals
                // that the caller should use `axis_length(axis)` for this representation.
                None
            }
            EdgeLengths::PerEdge { lengths } => lengths.get(edge_id).copied(),
        }
    }

    /// All edge lengths as a flat slice, if the geometry is per-edge.
    ///
    /// `Some(slice)` for PerEdge, `None` for the three uniform cases (where there is no
    /// materialized per-edge vector to slice).
    pub fn edge_lengths(&self) -> Option<&[R]> {
        match &self.edge_lengths {
            EdgeLengths::PerEdge { lengths } => Some(lengths.as_slice()),
            _ => None,
        }
    }

    /// Per-axis timelike flag pattern. `None` on the [`Euclidean`] variant, `Some(..)`
    /// on the [`Lorentzian`] variant.
    pub fn timelike_axes(&self) -> Option<&[bool; D]> {
        self.timelike_axes.as_ref()
    }

    /// `true` iff this geometry's type-level signature marker is [`Lorentzian`].
    ///
    /// Determined entirely at the type level — `Euclidean` always returns `false`,
    /// `Lorentzian` always returns `true`. The runtime `timelike_axes` field is
    /// consulted only by [`signature`](Self::signature).
    pub fn is_lorentzian(&self) -> bool {
        S::is_lorentzian()
    }

    /// Local metric signature for the cubical complex.
    ///
    /// On the [`Euclidean`] variant this is `Metric::Euclidean(D)`. On the
    /// [`Lorentzian`] variant the *per-axis* timelike pattern is preserved:
    /// if axis 0 is the only timelike axis, returns `Metric::Lorentzian(D)`
    /// (East-Coast canonical); otherwise returns `Metric::Custom { dim: D,
    /// neg_mask, zero_mask: 0 }` with `neg_mask` bit `i` set iff axis `i` is
    /// timelike.
    ///
    /// Returning `Custom` instead of the lossy `Lorentzian(D)` for non-axis-0
    /// timelike patterns is the R5.7 fix from the `deep_causality_metric`
    /// integration: downstream callers can recover *which* axis is timelike
    /// via `Metric::sign_of_sq(axis)` rather than just *how many*.
    ///
    /// Falls back to `Metric::Custom` for `D > 64` (bitmask capacity); current
    /// supported `D ≤ 4` is well within range.
    pub fn signature(&self) -> Metric {
        let Some(pattern) = self.timelike_axes.as_ref() else {
            return Metric::Euclidean(D);
        };
        // East-Coast canonical: axis 0 is the only timelike axis.
        if D > 0 && pattern[0] && pattern.iter().skip(1).all(|&t| !t) {
            return Metric::Lorentzian(D);
        }
        // Per-axis Custom for any other pattern (including axis-2-timelike etc.)
        let mut neg_mask = 0u64;
        for (i, &t) in pattern.iter().enumerate() {
            if t && i < 64 {
                neg_mask |= 1u64 << i;
            }
        }
        Metric::Custom {
            dim: D,
            neg_mask,
            zero_mask: 0,
        }
    }

    /// Resolve the edge length along `axis` at the given vertex position,
    /// dispatching on the geometry's edge-length representation. Mirrors the
    /// dispatch in `cell_volume`. Shared by `metric_tensor_at` and the action
    /// gradient (R6); `pub(super)` so sibling submodules can read it without
    /// going through the public per-edge / per-axis accessors.
    pub(super) fn axis_length_at_position(
        &self,
        complex: &crate::types::lattice_complex::LatticeComplex<D, R>,
        position: [usize; D],
        axis: usize,
    ) -> R {
        match &self.edge_lengths {
            EdgeLengths::UnitEdge => R::one(),
            EdgeLengths::Uniform { length } => *length,
            EdgeLengths::PerAxis { lengths } => lengths[axis],
            EdgeLengths::PerEdge { lengths } => {
                let shape = complex.shape();
                let is_periodic = complex.periodic()[axis];
                let max_edge_pos = if is_periodic {
                    shape[axis]
                } else if shape[axis] == 0 {
                    return R::one();
                } else {
                    shape[axis] - 1
                };
                let mut probe = position;
                if position[axis] < max_edge_pos {
                    probe[axis] = position[axis];
                } else if position[axis] > 0 {
                    probe[axis] = position[axis] - 1;
                } else {
                    return R::one();
                }
                let idx = complex.edge_index(probe, axis);
                // A `PerEdge` lengths vector whose `len()` does not match the
                // lattice's edge count is malformed geometry input. Silently
                // substituting `R::one()` for an out-of-range index would mask
                // the bug and yield wrong-but-plausible metric / gradient
                // values downstream. Fail loud instead.
                *lengths.get(idx).unwrap_or_else(|| {
                    panic!(
                        "PerEdge edge_lengths.len() = {} does not cover edge_index(probe = {:?}, axis = {}) = {}; \
                         the lengths vector must be sized to match the lattice's edge count (sum over axes of edges_along(axis))",
                        lengths.len(),
                        probe,
                        axis,
                        idx,
                    )
                })
            }
        }
    }
}
