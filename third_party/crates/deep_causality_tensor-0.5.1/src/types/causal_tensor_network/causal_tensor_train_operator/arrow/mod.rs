/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! `Arrow` realization of the MPO: an operator is an endo-arrow on the tensor-train state space.
//!
//! `run` applies the operator and rounds with the embedded `round_policy`, so the blanket
//! [`EndoArrow`](deep_causality_haft::EndoArrow) methods (`iterate_n`, `iterate_to_fixpoint`,
//! `iterate_until`) become a **bounded** tensor-train time-march. `compose` (`>>>`) and the rest of
//! the `Arrow` combinator surface come from the trait defaults.

use crate::traits::tensor_train_operator::TensorTrainOperator;
use crate::types::causal_tensor_network::causal_tensor_train::CausalTensorTrain;
use crate::types::causal_tensor_network::causal_tensor_train_operator::CausalTensorTrainOperator;
use deep_causality_algebra::ConjugateScalar;
use deep_causality_haft::Arrow;

impl<T> Arrow for CausalTensorTrainOperator<T>
where
    T: ConjugateScalar,
{
    type In = CausalTensorTrain<T>;
    type Out = CausalTensorTrain<T>;

    fn run(&self, input: Self::In) -> Self::Out {
        self.apply(&input, &self.round_policy)
            .expect("MPO Arrow::run: state dimensions must match the operator's input dimensions")
    }
}
