/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Identifiable;
use crate::types::context_node_types::data::Data;

impl<T> Identifiable for Data<T>
where
    T: Default + Copy + Clone + PartialEq,
{
    fn id(&self) -> u64 {
        self.id
    }
}
