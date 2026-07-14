/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{MaybeUncertain, Uncertain};
use deep_causality_num::Float106;

pub type UncertainBool = Uncertain<bool>;
pub type UncertainF64 = Uncertain<f64>;
pub type UncertainF106 = Uncertain<Float106>;

pub type MaybeUncertainBool = MaybeUncertain<bool>;
pub type MaybeUncertainF64 = MaybeUncertain<f64>;
pub type MaybeUncertainF106 = MaybeUncertain<Float106>;
