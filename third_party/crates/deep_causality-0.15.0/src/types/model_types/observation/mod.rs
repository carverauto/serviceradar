/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{IdentificationValue, NumericalValue};

mod display;
mod identifiable;
mod observable;

#[derive(Debug, Clone, PartialEq, PartialOrd)]
pub struct Observation {
    id: IdentificationValue,
    observation: NumericalValue,
    observed_effect: NumericalValue,
}

impl Observation {
    pub fn new(
        id: IdentificationValue,
        observation: NumericalValue,
        observed_effect: NumericalValue,
    ) -> Self {
        Self {
            id,
            observation,
            observed_effect,
        }
    }
}
