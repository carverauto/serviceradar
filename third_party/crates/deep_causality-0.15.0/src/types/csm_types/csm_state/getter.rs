/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalState, Causaloid, PropagatingEffect, UncertainParameter};
use std::fmt::Debug;

impl<I, O, C> CausalState<I, O, C>
where
    I: Default,
    O: Default + Debug,
    C: Clone,
{
    pub fn id(&self) -> usize {
        self.id
    }

    pub fn version(&self) -> usize {
        self.version
    }

    pub fn data(&self) -> &PropagatingEffect<I> {
        &self.data
    }

    pub fn causaloid(&self) -> &Causaloid<I, O, (), C> {
        &self.causaloid
    }

    pub fn context(&self) -> &C {
        self.causaloid
            .context()
            .as_ref()
            .expect("Context is required for CausalState but was None")
    }

    pub fn uncertain_parameter(&self) -> &Option<UncertainParameter> {
        &self.uncertain_parameter
    }
}
