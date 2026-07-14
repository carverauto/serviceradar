/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{DescriptionValue, IdentificationValue, NumericalValue};

mod display;
mod identifiable;
mod inferable;

#[derive(Debug, Clone, PartialEq, PartialOrd)]
pub struct Inference {
    id: IdentificationValue,
    question: DescriptionValue,
    observation: NumericalValue,
    threshold: NumericalValue,
    effect: NumericalValue,
    target: NumericalValue,
}

impl Inference {
    pub fn new(
        id: IdentificationValue,
        question: DescriptionValue,
        observation: NumericalValue,
        threshold: NumericalValue,
        effect: NumericalValue,
        target: NumericalValue,
    ) -> Self {
        Self {
            id,
            question,
            observation,
            threshold,
            effect,
            target,
        }
    }
}
