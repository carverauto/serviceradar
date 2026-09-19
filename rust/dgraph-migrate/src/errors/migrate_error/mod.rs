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

mod migrate_error_display;
mod migrate_error_error;

use crate::errors::ModeError;
use crate::types::SchemaReport;

/// Why a schema run failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrateError(MigrateErrorEnum);

/// Classification of [`MigrateError`].
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum MigrateErrorEnum {
    /// The environment did not select a valid, permitted mode.
    Mode(ModeError),
    /// The environment did not resolve to a Dgraph to talk to.
    Endpoint(String),
    /// The cluster could not be reached.
    Connect { target: String, reason: String },
    /// A schema operation failed.
    Schema(String),
    /// `alter` reported success and the schema is still not complete.
    StillIncomplete(SchemaReport),
    /// Removal reported success and part of the schema is still present.
    StillPresent(SchemaReport),
}

impl MigrateError {
    pub(crate) fn new(variant: MigrateErrorEnum) -> Self {
        Self(variant)
    }

    /// Classification, for callers that need to branch on the failure.
    #[must_use]
    pub fn kind(&self) -> &MigrateErrorEnum {
        &self.0
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn Mode(err: ModeError) -> Self {
        Self::new(MigrateErrorEnum::Mode(err))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn Endpoint(reason: String) -> Self {
        Self::new(MigrateErrorEnum::Endpoint(reason))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn Connect(target: String, reason: String) -> Self {
        Self::new(MigrateErrorEnum::Connect { target, reason })
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn Schema(reason: String) -> Self {
        Self::new(MigrateErrorEnum::Schema(reason))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn StillIncomplete(report: SchemaReport) -> Self {
        Self::new(MigrateErrorEnum::StillIncomplete(report))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn StillPresent(report: SchemaReport) -> Self {
        Self::new(MigrateErrorEnum::StillPresent(report))
    }
}
