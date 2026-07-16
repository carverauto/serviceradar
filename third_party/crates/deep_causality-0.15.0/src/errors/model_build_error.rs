/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{ModelGenerativeError, ModelValidationError};
use std::error::Error;
use std::fmt;
use std::fmt::{Display, Formatter};

#[derive(Debug, Clone, Hash, Eq, PartialEq)]
pub enum ModelBuildError {
    GenerationFailed(ModelGenerativeError),
    ValidationFailed(ModelValidationError),
}

impl Error for ModelBuildError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            ModelBuildError::GenerationFailed(e) => Some(e),
            ModelBuildError::ValidationFailed(e) => Some(e),
        }
    }
}

impl Display for ModelBuildError {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        match self {
            ModelBuildError::GenerationFailed(e) => {
                write!(f, "The generation process failed: {e}")
            }
            ModelBuildError::ValidationFailed(e) => {
                write!(
                    f,
                    "The generative output was invalid for model construction: {e}"
                )
            }
        }
    }
}

impl From<ModelGenerativeError> for ModelBuildError {
    fn from(value: ModelGenerativeError) -> Self {
        ModelBuildError::GenerationFailed(value)
    }
}

impl From<ModelValidationError> for ModelBuildError {
    fn from(value: ModelValidationError) -> Self {
        ModelBuildError::ValidationFailed(value)
    }
}
