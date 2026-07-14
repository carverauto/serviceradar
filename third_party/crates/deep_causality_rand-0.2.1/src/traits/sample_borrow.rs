/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::SampleUniform;

pub trait SampleBorrow<Borrowed> {
    fn borrow(&self) -> &Borrowed;
}

impl<Borrowed> SampleBorrow<Borrowed> for Borrowed
where
    Borrowed: SampleUniform,
{
    #[inline(always)]
    fn borrow(&self) -> &Borrowed {
        self
    }
}

impl<Borrowed> SampleBorrow<Borrowed> for &Borrowed
where
    Borrowed: SampleUniform,
{
    #[inline(always)]
    fn borrow(&self) -> &Borrowed {
        self
    }
}
