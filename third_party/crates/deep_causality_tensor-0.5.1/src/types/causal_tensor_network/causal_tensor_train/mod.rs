/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod algebra;
mod api;
mod construct;
mod getters;
pub(crate) mod linalg;
mod round_rand;

use crate::types::causal_tensor_network::canonical_form::CanonicalForm;
use crate::{CausalTensor, CausalTensorError};
use deep_causality_algebra::ConjugateScalar;

/// A tensor-train (matrix-product-state) factorization of a rank-`order` tensor.
///
/// A rank-`d` tensor `A[i₀, …, i_{d-1}]` is stored as a chain of rank-3 **cores** `G_k` of shape
/// `[r_k, n_k, r_{k+1}]`, with boundary bonds `r₀ = r_d = 1`:
///
/// ```text
/// A[i₀,…,i_{d-1}] = G₀[:, i₀, :] · G₁[:, i₁, :] · … · G_{d-1}[:, i_{d-1}, :]
/// ```
///
/// Fields are private; access is through getters. Precision is the scalar parameter `T`, carried
/// generically at every stage (`f32` / `f64` / `Float106`, and — by the `Scalar` bound — the dual
/// number for forward-mode AD).
///
/// A train may also be one of two **shape-polymorphic algebraic identities** (`Identity`): the
/// additive `0` and the multiplicative (Hadamard) `1`. These are order-0 (no cores) and act as the
/// neutral element under `+` / `*` against a train of *any* shape — the tensor-train analogue of
/// `CausalTensor`'s broadcasting scalar zero. They let `CausalTensorTrain` be a genuine
/// `deep_causality_num` `AddGroup` / `Module` / `Ring`.
#[derive(Debug, Clone, PartialEq)]
pub struct CausalTensorTrain<T> {
    /// Cores `0..order`; core `k` has shape `[r_k, n_k, r_{k+1}]`. Empty for an identity.
    cores: Vec<CausalTensor<T>>,
    /// Cached physical dimensions `[n_0, …, n_{order-1}]`.
    phys_dims: Vec<usize>,
    /// Tracked orthogonality structure.
    canonical: CanonicalForm,
    /// Whether this is an ordinary train or a shape-polymorphic algebraic identity.
    identity: Identity,
}

/// Whether a [`CausalTensorTrain`] is an ordinary train or one of the two algebraic identities.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum Identity {
    /// An ordinary tensor train (`order ≥ 1`).
    #[default]
    Normal,
    /// The additive identity `0`: neutral under `+`.
    AdditiveZero,
    /// The multiplicative (Hadamard) identity `1`: neutral under `*`.
    MultiplicativeOne,
}

impl<T> CausalTensorTrain<T> {
    /// Builds a train directly from cores and a known canonical form, without any bound or
    /// validation. Used by structure-preserving maps (the HKT functor) where `T` need not be a
    /// `Scalar`. Callers must guarantee the bond structure.
    pub(crate) fn from_cores_raw(cores: Vec<CausalTensor<T>>, canonical: CanonicalForm) -> Self {
        let phys_dims = cores.iter().map(|c| c.shape()[1]).collect();
        Self {
            cores,
            phys_dims,
            canonical,
            identity: Identity::Normal,
        }
    }

    /// Builds one of the two shape-polymorphic algebraic identities (no cores).
    pub(crate) fn identity_train(identity: Identity) -> Self {
        Self {
            cores: Vec::new(),
            phys_dims: Vec::new(),
            canonical: CanonicalForm::None,
            identity,
        }
    }

    /// Which algebraic identity (if any) this train is.
    pub(crate) fn identity_kind(&self) -> Identity {
        self.identity
    }

    /// Consumes the train, returning its cores (for structure-preserving maps).
    pub(crate) fn into_cores(self) -> Vec<CausalTensor<T>> {
        self.cores
    }
}

impl<T> CausalTensorTrain<T>
where
    T: ConjugateScalar,
{
    /// Builds a tensor train from an explicit chain of rank-3 cores, validating the bond structure.
    ///
    /// # Errors
    /// - [`CausalTensorError::EmptyTensor`] if `cores` is empty or any core has a zero dimension.
    /// - [`CausalTensorError::DimensionMismatch`] if any core is not 3-dimensional.
    /// - [`CausalTensorError::BondDimensionMismatch`] if the boundary bonds are not 1 or adjacent
    ///   cores disagree on the shared bond.
    pub fn from_cores(cores: Vec<CausalTensor<T>>) -> Result<Self, CausalTensorError> {
        if cores.is_empty() {
            return Err(CausalTensorError::EmptyTensor);
        }
        for core in &cores {
            if core.shape().len() != 3 {
                return Err(CausalTensorError::DimensionMismatch);
            }
            if core.shape().contains(&0) {
                return Err(CausalTensorError::EmptyTensor);
            }
        }
        // Boundary bonds must be 1.
        if cores[0].shape()[0] != 1 || cores[cores.len() - 1].shape()[2] != 1 {
            return Err(CausalTensorError::BondDimensionMismatch);
        }
        // Adjacent cores must agree on the shared bond.
        for pair in cores.windows(2) {
            if pair[0].shape()[2] != pair[1].shape()[0] {
                return Err(CausalTensorError::BondDimensionMismatch);
            }
        }
        Ok(Self::from_cores_raw(cores, CanonicalForm::None))
    }

    /// Constructs a tensor train internally from validated cores without re-checking, recording the
    /// given canonical form.
    pub(crate) fn from_cores_unchecked(
        cores: Vec<CausalTensor<T>>,
        canonical: CanonicalForm,
    ) -> Self {
        Self::from_cores_raw(cores, canonical)
    }

    /// The all-zeros tensor of the given physical dimensions, as a rank-1 train.
    pub fn zeros(phys_dims: &[usize]) -> Self {
        let cores = phys_dims
            .iter()
            .map(|&n| CausalTensor::new(vec![T::zero(); n], vec![1, n, 1]).unwrap())
            .collect();
        Self::from_cores_unchecked(cores, CanonicalForm::None)
    }

    /// The all-ones tensor of the given physical dimensions, as a rank-1 train (the multiplicative
    /// identity under the Hadamard product).
    pub fn ones(phys_dims: &[usize]) -> Self {
        let cores = phys_dims
            .iter()
            .map(|&n| CausalTensor::new(vec![T::one(); n], vec![1, n, 1]).unwrap())
            .collect();
        Self::from_cores_unchecked(cores, CanonicalForm::None)
    }

    /// A deterministically-seeded random tensor train with the given physical dimensions and a
    /// uniform interior bond dimension, with entries in `[-1, 1)`.
    ///
    /// Uses a self-contained `splitmix64` stream so the constructor needs no external RNG crate and
    /// produces reproducible data for tests, benchmarks, and iterative-solver initialization. Entries
    /// are sampled at the **working precision** of `T` (see `crate::types::causal_tensor_network::rng`),
    /// so a `Float106` train carries full double-double precision rather than `f64`-pinned values.
    pub fn random_seeded(phys_dims: &[usize], bond: usize, seed: u64) -> Self {
        use crate::types::causal_tensor_network::rng::uniform_signed;
        let bond = bond.max(1);
        let d = phys_dims.len();
        let mut state = seed;
        let mut next = || -> T { uniform_signed::<T>(&mut state) };

        let cores = (0..d)
            .map(|k| {
                let r_left = if k == 0 { 1 } else { bond };
                let r_right = if k == d - 1 { 1 } else { bond };
                let n = phys_dims[k];
                let data = (0..r_left * n * r_right).map(|_| next()).collect();
                CausalTensor::new(data, vec![r_left, n, r_right]).unwrap()
            })
            .collect();
        Self::from_cores_unchecked(cores, CanonicalForm::None)
    }
}
