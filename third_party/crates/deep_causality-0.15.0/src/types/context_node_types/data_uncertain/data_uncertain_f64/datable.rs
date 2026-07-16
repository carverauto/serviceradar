/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Datable, UncertainFloat64Data};
use deep_causality_uncertain::UncertainF64;

/// Implements the `Datable` trait for `UncertainF64`.
///
impl Datable for UncertainFloat64Data {
    type Data = UncertainF64;

    fn get_data(&self) -> Self::Data {
        self.data.clone()
    }

    fn set_data(&mut self, value: Self::Data) {
        self.data = value;
    }
}
