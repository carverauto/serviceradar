/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::model_types::assumption::Assumption;
use crate::{Assumable, AssumptionError, DescriptionValue, PropagatingEffect};

impl Assumable for Assumption {
    fn description(&self) -> DescriptionValue {
        self.description.to_string() as DescriptionValue
    }

    fn assumption_tested(&self) -> bool {
        *self.assumption_tested.read().unwrap()
    }

    fn assumption_valid(&self) -> bool {
        *self.assumption_valid.read().unwrap()
    }

    fn verify_assumption(&self, data: &[PropagatingEffect<f64>]) -> Result<bool, AssumptionError> {
        let res = (self.assumption_fn)(data)?;

        let mut guard_tested = self.assumption_tested.write().unwrap();
        *guard_tested = true;

        if res {
            let mut guard_valid = self.assumption_valid.write().unwrap();
            *guard_valid = true;
        } else {
            let mut guard_valid = self.assumption_valid.write().unwrap();
            *guard_valid = false;
        }

        Ok(res)
    }
}
