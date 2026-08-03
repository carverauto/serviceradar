/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Type-level metric signature markers for `CubicalReggeGeometry<D, R, S>` —
//! Phase R5.1.
//!
//! Two marker types — [`Euclidean`] and [`Lorentzian`] — implement a sealed
//! capability trait [`SignatureMarker`]. The `CubicalReggeGeometry` type is
//! generic over a third parameter `S: SignatureMarker` defaulted to
//! `Euclidean`, preserving R1–R3 / R4 source compatibility while letting
//! Lorentzian-flavoured operations (light-cone enforcement, Wick-rotated
//! action, signed Hodge ⋆) be tracked at the type level.
//!
//! # Sealing
//!
//! The trait is sealed via the standard private-supertrait pattern so third
//! parties cannot add degenerate or split-signature variants without
//! coordinating with the differential-operator code, per design.md
//! Decision 3 and the "Trade-off — Sealed `SignatureMarker` trait" note.
//! The seal can be relaxed later if a concrete need appears.
//!
//! # `Cell::sign_factor`
//!
//! The trait exposes a `sign_factor(timelike_count)` method that the
//! Lorentzian Hodge ⋆ uses to apply `(−1)^t` where `t` is the number of
//! timelike axes in the primal cell's active dimensions. `Euclidean` always
//! returns `+1`. This is the dispatch point that lets the cubical
//! `HasHodgeStar<R>` impl be generic over `S` (R5.4).

use deep_causality_algebra::RealField;
mod sealed {
    pub trait Sealed {}
}

/// Capability trait for `CubicalReggeGeometry<D, R, S>` signature markers.
///
/// Sealed — only [`Euclidean`] and [`Lorentzian`] implement this trait.
pub trait SignatureMarker:
    sealed::Sealed + 'static + Copy + core::fmt::Debug + PartialEq + Eq + Default
{
    /// Sign factor `(−1)^t` to apply to the Hodge ⋆ diagonal entry for a
    /// primal cell whose active axes include `timelike_count` timelike axes.
    ///
    /// - [`Euclidean`] always returns `+R::one()` regardless of `timelike_count`.
    /// - [`Lorentzian`] returns `-R::one()` when `timelike_count` is odd,
    ///   `+R::one()` when even.
    fn sign_factor<R: RealField>(timelike_count: usize) -> R;

    /// `true` iff this signature has at least one timelike axis at the
    /// type level. Used by impl-block bounds to gate Lorentzian-only methods.
    fn is_lorentzian() -> bool;
}

/// Euclidean signature: all axes spacelike, signature `(+, +, …, +)`.
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub struct Euclidean;

impl sealed::Sealed for Euclidean {}

impl SignatureMarker for Euclidean {
    fn sign_factor<R: RealField>(_timelike_count: usize) -> R {
        R::one()
    }

    fn is_lorentzian() -> bool {
        false
    }
}

/// Lorentzian signature: at least one timelike axis, East-Coast convention
/// `(−, +, …, +)` (or equivalent permutation per the per-axis `timelike_axes`
/// flag carried on `CubicalReggeGeometry`).
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub struct Lorentzian;

impl sealed::Sealed for Lorentzian {}

impl SignatureMarker for Lorentzian {
    fn sign_factor<R: RealField>(timelike_count: usize) -> R {
        if timelike_count.is_multiple_of(2) {
            R::one()
        } else {
            -R::one()
        }
    }

    fn is_lorentzian() -> bool {
        true
    }
}
