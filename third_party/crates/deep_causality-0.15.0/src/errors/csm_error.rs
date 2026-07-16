/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{ActionError, CausalityError};
use deep_causality_uncertain::UncertainError;
use std::error::Error;
use std::fmt::{Display, Formatter};

#[derive(Debug)]
pub enum CsmError {
    Action(ActionError),
    Causal(CausalityError),
    Forbidden(String),
    Uncertain(String),
}

impl Error for CsmError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            CsmError::Action(e) => Some(e),
            CsmError::Causal(e) => Some(e),
            CsmError::Forbidden(_) => None,
            CsmError::Uncertain(_) => None,
        }
    }
}

impl Display for CsmError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            CsmError::Action(e) => write!(f, "CSM Action Error: {e}"),
            CsmError::Causal(e) => write!(f, "CSM Causal Error: {e}"),
            CsmError::Forbidden(s) => write!(f, "CSM Forbidden: {s}"),
            CsmError::Uncertain(s) => write!(f, "CSM Uncertain Error: {s}"),
        }
    }
}

impl From<ActionError> for CsmError {
    fn from(err: ActionError) -> Self {
        CsmError::Action(err)
    }
}

impl From<CausalityError> for CsmError {
    fn from(err: CausalityError) -> Self {
        CsmError::Causal(err)
    }
}

impl From<UncertainError> for CsmError {
    fn from(err: UncertainError) -> Self {
        CsmError::Uncertain(err.to_string())
    }
}
