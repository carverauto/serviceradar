/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalState, Causaloid, CsmError};
use crate::{CsmEvaluable, MonadicCausable};
use deep_causality_core::PropagatingEffect;
use std::fmt::Debug;

impl<I, O, C> CausalState<I, O, C>
where
    I: Default + Clone + Debug + Send + Sync,
    O: CsmEvaluable + Default + Debug + Clone + Send + Sync,
    C: Clone + Send + Sync,
    Causaloid<I, O, (), C>: MonadicCausable<I, O>,
{
    /// Evaluates the state using its internal data.
    ///
    /// This method uses the state's causaloid to determine if the state's conditions
    /// are met based on the internal data value.
    ///
    /// # Returns
    /// - `Ok(PropagatingEffect<O>)` if evaluation succeeds
    /// - `Err(CausalStateError)` if an error occurs during evaluation
    ///
    pub fn eval(&self) -> Result<PropagatingEffect<O>, CsmError> {
        Ok(self.causaloid.evaluate(&self.data))
    }

    /// Evaluates the state using provided external data.
    ///
    /// This method uses the state's causaloid to determine if the state's conditions
    /// are met based on the provided data value, rather than the internal data.
    ///
    /// # Parameters
    /// - `data`: The numerical value to use for evaluation
    ///
    /// # Returns
    /// - `Ok(PropagatingEffect<O>)` if evaluation succeeds
    /// - `Err(CsmError)` if an error occurs during evaluation
    ///
    pub fn eval_with_data(
        &self,
        data: &PropagatingEffect<I>,
    ) -> Result<PropagatingEffect<O>, CsmError> {
        Ok(self.causaloid.evaluate(data))
    }
}
