/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensor;

impl<T: std::fmt::Display> std::fmt::Display for CausalTensor<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "CausalTensor {{ data: [")?;
        let max_items = 10;
        for (i, item) in self.data.iter().take(max_items).enumerate() {
            if i > 0 {
                write!(f, ", ")?;
            }
            write!(f, "{}", item)?;
        }
        if self.data.len() > max_items {
            write!(f, ", ...")?;
        }
        write!(
            f,
            "], shape: {:?}, strides: {:?} }}",
            self.shape, self.strides
        )
    }
}
