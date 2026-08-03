/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensor;
use crate::types::causal_tensor_network::canonical_form::CanonicalForm;
use crate::types::causal_tensor_network::causal_tensor_train::CausalTensorTrain;
use deep_causality_haft::{Foldable, Functor, HKT, NoConstraint, Pure, Satisfies};

// ============================================================================
// HKT Witness
// ============================================================================

/// HKT witness for [`CausalTensorTrain`].
///
/// Only the **storage functor** is provided: `Functor`/`Foldable`/`Pure` act on the *scalar type of
/// the cores*, not on the logical dense entries of the represented tensor. `fmap` therefore converts
/// precision (`f64 → f32`) or lifts a real into a dual for forward-mode AD, leaving the bond and
/// physical structure untouched.
///
/// `Monad`, `CoMonad`, and `Applicative` are deliberately **absent**: a list-style `bind` has no
/// counterpart in a factored chain, a comonadic stencil on a compressed train is exactly an MPO, and
/// a train of closures is not a sensible payload. See the design note for the full rationale.
pub struct CausalTensorTrainWitness;

impl HKT for CausalTensorTrainWitness {
    type Constraint = NoConstraint;
    type Type<T>
        = CausalTensorTrain<T>
    where
        T: Satisfies<NoConstraint>;
}

// ============================================================================
// Functor — maps the scalar type of every core (structure-preserving)
// ============================================================================

impl Functor<CausalTensorTrainWitness> for CausalTensorTrainWitness {
    fn fmap<A, B, Func>(m_a: CausalTensorTrain<A>, mut f: Func) -> CausalTensorTrain<B>
    where
        A: Satisfies<NoConstraint>,
        B: Satisfies<NoConstraint>,
        Func: FnMut(A) -> B,
    {
        let new_cores: Vec<CausalTensor<B>> = m_a
            .into_cores()
            .into_iter()
            .map(|core| {
                let shape = core.shape().to_vec();
                let data: Vec<B> = core.into_vec().into_iter().map(&mut f).collect();
                CausalTensor::from_vec(data, &shape)
            })
            .collect();
        // Applying `f` to the stored entries does not preserve orthogonality.
        CausalTensorTrain::from_cores_raw(new_cores, CanonicalForm::None)
    }
}

// ============================================================================
// Foldable — folds over every core entry (the factors, not the logical tensor)
// ============================================================================

impl Foldable<CausalTensorTrainWitness> for CausalTensorTrainWitness {
    fn fold<A, B, Func>(fa: CausalTensorTrain<A>, init: B, mut f: Func) -> B
    where
        A: Satisfies<NoConstraint>,
        Func: FnMut(B, A) -> B,
    {
        let mut acc = init;
        for core in fa.into_cores() {
            for a in core.into_vec() {
                acc = f(acc, a);
            }
        }
        acc
    }
}

// ============================================================================
// Pure — lifts a scalar to the rank-1 boundary train representing it
// ============================================================================

impl Pure<CausalTensorTrainWitness> for CausalTensorTrainWitness {
    fn pure<T>(value: T) -> CausalTensorTrain<T>
    where
        T: Satisfies<NoConstraint>,
    {
        let core = CausalTensor::from_vec(vec![value], &[1, 1, 1]);
        CausalTensorTrain::from_cores_raw(vec![core], CanonicalForm::None)
    }
}
