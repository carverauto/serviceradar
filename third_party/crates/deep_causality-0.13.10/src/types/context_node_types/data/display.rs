/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Data;
use std::fmt::{Debug, Display, Formatter};

impl<T> Display for Data<T>
where
    T: Debug + Default + Copy + Clone + PartialEq,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "Dataoid: id: {} data: {:?}", self.id, self.data)
    }
}
