/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tier-2 iso witness for the de Rham (♭) / sharp (♯) transfer pair.
//!
//! The operator methods live on the manifold
//! (`Manifold::{de_rham, de_rham_from_integrals, sharp}` in
//! `types::manifold::differential::de_rham`); this extension provides the
//! witness-pattern encoding against `deep_causality_algebra::iso::witness::Iso`,
//! per the crate convention that type extensions and witness implementations
//! live under `extensions/`.
//!
//! The carrier is `(manifold, field)`: `to_target` applies the de Rham map to
//! a vertex vector field, `to_source` applies the sharp map to an edge
//! cochain. The pair is an isomorphism **up to discretization order** — exact
//! on constant fields (where the witness satisfies the exact round-trip law),
//! `O(h²)` on smooth fields. Conversion failures (length mismatch, missing
//! metric) are programming errors at this level and panic; use the fallible
//! `Manifold::{de_rham, sharp}` methods directly where errors must propagate.

use deep_causality_algebra::RealField;
use deep_causality_algebra::iso::witness::Iso;
use deep_causality_num::FromPrimitive;
use deep_causality_par::MaybeParallel;
use deep_causality_tensor::CausalTensor;

use crate::types::lattice_complex::LatticeComplex;
use crate::types::manifold::Manifold;

/// Zero-sized witness for the de Rham/sharp transfer pair. See module doc.
pub struct DeRhamSharpIso<const D: usize, R: RealField>(core::marker::PhantomData<R>);

/// Iso carrier for the de Rham/sharp transfer: a manifold paired with a field
/// tensor (vertex vectors on the source side, an edge cochain on the target
/// side).
pub type FieldCarrier<const D: usize, R> = (Manifold<LatticeComplex<D, R>, R>, CausalTensor<R>);

impl<const D: usize, R> Iso<FieldCarrier<D, R>, FieldCarrier<D, R>> for DeRhamSharpIso<D, R>
where
    R: RealField + MaybeParallel + FromPrimitive + Default + PartialEq + core::fmt::Debug,
{
    fn to_target(s: FieldCarrier<D, R>) -> FieldCarrier<D, R> {
        let (manifold, vertex_vectors) = s;
        let cochain = manifold
            .de_rham(&vertex_vectors)
            .expect("DeRhamSharpIso::to_target: carrier invariants violated");
        (manifold, cochain)
    }

    fn to_source(t: FieldCarrier<D, R>) -> FieldCarrier<D, R> {
        let (manifold, edge_cochain) = t;
        let vectors = manifold
            .sharp(&edge_cochain)
            .expect("DeRhamSharpIso::to_source: carrier invariants violated");
        (manifold, vectors)
    }
}
