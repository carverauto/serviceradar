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

use crate::types::SchemaReport;

/// Nothing needed doing: the schema was already current, or a status run succeeded.
pub const EXIT_CURRENT: u8 = 0;

/// A migration was applied.
pub const EXIT_MIGRATED: u8 = 10;

/// The schema was deprovisioned.
pub const EXIT_DEPROVISIONED: u8 = 20;

/// The operation failed.
pub const EXIT_FAILED: u8 = 1;

/// The environment was rejected.
pub const EXIT_REJECTED: u8 = 2;

/// What a run did.
///
/// Carries the schema report rather than a bare flag, so a caller can log
/// precisely what was missing without repeating the query.
#[derive(Debug, Clone, Eq, PartialEq)]
pub enum Outcome {
    /// The schema was already current. Nothing was written.
    AlreadyCurrent,
    /// The schema was applied. The report describes what had been missing beforehand.
    Migrated(SchemaReport),
    /// The schema was removed.
    Deprovisioned,
    /// A read-only report. Nothing was written.
    Status(SchemaReport),
}

impl Outcome {
    /// Whether the cluster was modified.
    #[must_use]
    pub const fn changed_the_cluster(&self) -> bool {
        matches!(self, Self::Migrated(_) | Self::Deprovisioned)
    }

    /// Process exit code this outcome maps to.
    ///
    /// Only `0` is a shell success: a wrapper chaining with `&&` after a run
    /// that actually migrated will see `10` and stop. That is intentional.
    #[must_use]
    pub const fn exit_code(&self) -> u8 {
        match self {
            Self::AlreadyCurrent | Self::Status(_) => EXIT_CURRENT,
            Self::Migrated(_) => EXIT_MIGRATED,
            Self::Deprovisioned => EXIT_DEPROVISIONED,
        }
    }
}
