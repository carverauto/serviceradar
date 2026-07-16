/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::UncertainFloat64Data;
use std::fmt::{Display, Formatter};

impl Display for UncertainFloat64Data {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "UncertainFloat64Data: id: {} data: {:?}",
            self.id, self.data
        )
    }
}
