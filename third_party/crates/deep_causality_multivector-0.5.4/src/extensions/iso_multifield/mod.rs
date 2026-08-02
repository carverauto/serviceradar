/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Structural iso between [`CausalMultiField<T>`] and its underlying
//! carrier tuple `(CausalTensor<T>, Metric, [T; 3], [usize; 3])`.
//!
//! This is a pack/unpack iso — no algebraic homomorphism is involved.
//! Neither side implements `Group`/`Ring`/`Field`, so no marker
//! subtraits are declared. The base `Iso<S, T>` is satisfied via the
//! [`StandardIso<S, T>`] blanket impl in `deep_causality_num` once
//! bidirectional `From` is in place.
//!
//! ## Why
//!
//! `CausalMultiField<T>` keeps its fields `pub(crate)`, which prevents
//! out-of-crate code from constructing or destructuring an instance.
//! Generic tensor operations that want to work on the underlying carrier
//! ((`CausalTensor<T>` + metric + grid spacing + grid shape)) need a
//! typed bridge. The iso provides exactly that without exposing the
//! internal field layout.
//!
//! ## Layout
//!
//! Lives under `src/extensions/iso_multifield/`, mirroring the
//! `hkt_multifield/` extension that already exists for HKT impls. No
//! feature flag: both `deep_causality_tensor` and `deep_causality_metric`
//! are already deps of multivector; no new transitive dep is
//! introduced.
//!
//! See `openspec/changes/implement-isomorphism/specs/iso-multifield-tensor/spec.md`.

use crate::CausalMultiField;
use deep_causality_metric::Metric;
use deep_causality_tensor::CausalTensor;

/// Carrier tuple for [`CausalMultiField<T>`].
///
/// Fields in declaration order: tensor data, Clifford metric, grid
/// spacing `[dx, dy, dz]`, grid shape `[Nx, Ny, Nz]`.
pub type MultiFieldCarrier<T> = (CausalTensor<T>, Metric, [T; 3], [usize; 3]);

// =============================================================================
// Forward: CausalMultiField<T> -> MultiFieldCarrier<T>
// =============================================================================

impl<T> From<CausalMultiField<T>> for MultiFieldCarrier<T> {
    /// Unpack a multifield into its four constituent fields without
    /// copying allocated data (move semantics on `data`; `metric`,
    /// `dx`, `shape` are owned by value).
    fn from(mf: CausalMultiField<T>) -> Self {
        (mf.data, mf.metric, mf.dx, mf.shape)
    }
}

// =============================================================================
// Reverse: MultiFieldCarrier<T> -> CausalMultiField<T>
// =============================================================================

impl<T> From<MultiFieldCarrier<T>> for CausalMultiField<T> {
    /// Pack a carrier tuple back into a multifield. No validation: the
    /// caller is responsible for ensuring the tensor shape is
    /// consistent with `shape` and `metric` (the same contract as the
    /// pub(crate) constructor used inside the multifield's own
    /// module).
    fn from(carrier: MultiFieldCarrier<T>) -> Self {
        let (data, metric, dx, shape) = carrier;
        CausalMultiField {
            data,
            metric,
            dx,
            shape,
        }
    }
}

// =============================================================================
// `StandardIso<CausalMultiField<T>, MultiFieldCarrier<T>>` is satisfied
// automatically via the blanket impl in `deep_causality_num`. No manual
// `Iso<S, T>` impl needed; no marker subtraits.
// =============================================================================
