/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use deep_causality_uncertain::UncertainF64;

mod adjustable;
mod datable;
mod display;
mod identifiable;

#[derive(Debug, Clone)]
pub struct UncertainFloat64Data {
    id: u64,
    data: UncertainF64,
}

impl UncertainFloat64Data {
    pub fn new(id: u64, data: UncertainF64) -> Self {
        Self { id, data }
    }
}
