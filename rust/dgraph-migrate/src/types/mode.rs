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

use crate::errors::ModeError;
use crate::types::Environment;
use crate::utils::mode_env::{CONFIRM_ENV, CONFIRM_VALUE, MODE_ENV, read};

/// What the run was asked to do.
#[derive(Debug, Clone, Copy, Default, Eq, PartialEq)]
pub enum Mode {
    /// Verify, and apply the schema only if something is missing. The default.
    #[default]
    Migrate,
    /// Report what the cluster has and change nothing.
    Status,
    /// Undo the migration, dropping the predicates and types the spec owns.
    Deprovision,
}

impl Mode {
    /// Read the mode from the process environment and check it against `env`.
    ///
    /// # Errors
    ///
    /// Returns [`ModeError`] for an unrecognised mode, or for a deprovision
    /// this environment does not permit.
    pub fn from_env(env: Option<Environment>) -> Result<Self, ModeError> {
        Self::resolve(read(MODE_ENV), read(CONFIRM_ENV), env)
    }

    /// The whole rule, as a pure function.
    ///
    /// Environment reading is kept out so every branch is testable without
    /// mutating process state.
    ///
    /// # Errors
    ///
    /// As [`Mode::from_env`].
    pub fn resolve(
        mode: Option<String>,
        confirm: Option<String>,
        env: Option<Environment>,
    ) -> Result<Self, ModeError> {
        let requested = match mode.as_deref().map(str::trim) {
            None | Some("") => Self::Migrate,
            Some(value) => match value.to_ascii_uppercase().as_str() {
                "MIGRATE" => Self::Migrate,
                "STATUS" => Self::Status,
                "DEPROVISION" => Self::Deprovision,
                _ => return Err(ModeError::Unrecognised(value.to_string())),
            },
        };

        if requested != Self::Deprovision {
            return Ok(requested);
        }

        let Some(env) = env else {
            return Err(ModeError::RefusedInUnknownEnvironment());
        };
        if env.deprovision_requires_confirm()
            && confirm.as_deref().map(str::trim) != Some(CONFIRM_VALUE)
        {
            return Err(ModeError::ConfirmationRequired());
        }

        Ok(Self::Deprovision)
    }

    /// Whether this mode may drop schema.
    #[must_use]
    pub const fn is_destructive(&self) -> bool {
        matches!(self, Self::Deprovision)
    }
}
