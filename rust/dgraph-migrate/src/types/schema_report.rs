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

/// What the cluster is missing, if anything.
///
/// An incomplete schema is an answer, not a failure: verification returns
/// this report and reserves `Err` for a cluster that could not be reached.
#[derive(Debug, Clone, Default, Eq, PartialEq)]
pub struct SchemaReport {
    missing_predicates: Vec<String>,
    missing_types: Vec<String>,
}

impl SchemaReport {
    /// Build a report from what the cluster was found to be missing.
    #[must_use]
    pub const fn new(missing_predicates: Vec<String>, missing_types: Vec<String>) -> Self {
        Self {
            missing_predicates,
            missing_types,
        }
    }

    /// Whether every predicate and type the spec owns is present.
    #[must_use]
    pub fn is_complete(&self) -> bool {
        self.missing_predicates.is_empty() && self.missing_types.is_empty()
    }

    /// Predicates the spec declares that the cluster does not have.
    #[must_use]
    pub fn missing_predicates(&self) -> &[String] {
        &self.missing_predicates
    }

    /// Types the spec declares that the cluster does not have.
    #[must_use]
    pub fn missing_types(&self) -> &[String] {
        &self.missing_types
    }
}
