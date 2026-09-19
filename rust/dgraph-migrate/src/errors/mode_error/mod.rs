/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

mod mode_error_display;
mod mode_error_error;

/// Why a migration mode could not be selected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModeError(ModeErrorEnum);

/// Classification of [`ModeError`].
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum ModeErrorEnum {
    /// `DGRAPH_MIGRATION_MODE` was set to a value this crate does not recognise.
    Unrecognised(String),
    /// Deprovision was requested in an environment that is not LOCAL, CI, or CLUSTER.
    RefusedInUnknownEnvironment,
    /// Deprovision against CLUSTER requires [`crate::CONFIRM_VALUE`].
    ConfirmationRequired,
}

impl ModeError {
    pub(crate) fn new(variant: ModeErrorEnum) -> Self {
        Self(variant)
    }

    /// Classification, for callers that need to branch on the failure.
    #[must_use]
    pub fn kind(&self) -> &ModeErrorEnum {
        &self.0
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn Unrecognised(value: String) -> Self {
        Self::new(ModeErrorEnum::Unrecognised(value))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn RefusedInUnknownEnvironment() -> Self {
        Self::new(ModeErrorEnum::RefusedInUnknownEnvironment)
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn ConfirmationRequired() -> Self {
        Self::new(ModeErrorEnum::ConfirmationRequired)
    }
}
