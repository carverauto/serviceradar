/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Data, Datable};

/// Implements the `Datable` trait for `Data<T>`.
///
/// This allows `Data<T>` to be used in contexts where a generic data container
/// is expected, providing methods to get and set the inner data payload.
impl<T> Datable for Data<T>
where
    T: Default + Copy + Clone + PartialEq,
{
    type Data = T;

    fn get_data(&self) -> Self::Data {
        self.data
    }

    fn set_data(&mut self, value: Self::Data) {
        self.data = value;
    }
}
