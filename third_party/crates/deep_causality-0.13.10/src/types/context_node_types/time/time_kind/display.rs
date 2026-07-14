/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Identifiable, Temporal, TimeKind};
use std::fmt;

impl fmt::Display for TimeKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TimeKind::Euclidean(t) => {
                write!(f, "EuclideanTime(id: {}, τ: {})", t.id(), t.time_unit())
            }
            TimeKind::Entropic(t) => {
                write!(f, "EntropicTime(id: {}, t: {})", t.id(), t.time_unit())
            }
            TimeKind::Discrete(t) => {
                write!(f, "DiscreteTime(id: {}, tick: {})", t.id(), t.time_unit())
            }
            TimeKind::Lorentzian(t) => {
                write!(f, "LorentzianTime(id: {}, t: {})", t.id(), t.time_unit())
            } // TimeKind::Symbolic(t) => write!(f, "SymbolicTime(id: {}, {})", t.id(), t),
        }
    }
}
