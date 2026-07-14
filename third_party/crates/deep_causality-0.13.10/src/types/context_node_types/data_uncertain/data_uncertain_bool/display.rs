/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::UncertainBooleanData;
use std::fmt::{Display, Formatter};

impl Display for UncertainBooleanData {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "UncertainBooleanData: id: {} data: {:?}",
            self.id, self.data
        )
    }
}
