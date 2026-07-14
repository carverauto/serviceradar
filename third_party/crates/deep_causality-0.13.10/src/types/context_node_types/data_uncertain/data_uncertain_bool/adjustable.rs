/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{AdjustmentError, UncertainAdjustable, UncertainBooleanData};
use deep_causality_uncertain::Uncertain;

impl UncertainAdjustable for UncertainBooleanData {
    type Data = Uncertain<bool>;

    fn update(&mut self, uncertain: Self::Data) -> Result<(), AdjustmentError> {
        self.data = uncertain;

        Ok(())
    }

    fn adjust(&mut self, uncertain: Self::Data) -> Result<(), AdjustmentError> {
        self.data = uncertain;

        Ok(())
    }
}
