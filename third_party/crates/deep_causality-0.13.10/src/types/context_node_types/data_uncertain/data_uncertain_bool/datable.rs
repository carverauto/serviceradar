/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Datable, UncertainBooleanData};
use deep_causality_uncertain::UncertainBool;

/// Implements the `Datable` trait for `DataUncertainBool`.
///
impl Datable for UncertainBooleanData {
    type Data = UncertainBool;

    fn get_data(&self) -> Self::Data {
        self.data.clone()
    }

    fn set_data(&mut self, value: Self::Data) {
        self.data = value;
    }
}
