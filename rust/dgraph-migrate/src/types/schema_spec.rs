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

/// Schema text plus the predicates and types it owns.
///
/// The product crate supplies these. This crate applies, verifies, and
/// removes exactly those names. It never calls `drop_all`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SchemaSpec {
    schema: &'static str,
    predicates: &'static [&'static str],
    types: &'static [&'static str],
}

impl SchemaSpec {
    /// Build a spec from the product schema.
    #[must_use]
    pub const fn new(
        schema: &'static str,
        predicates: &'static [&'static str],
        types: &'static [&'static str],
    ) -> Self {
        Self {
            schema,
            predicates,
            types,
        }
    }

    /// DQL schema text passed to `set_schema`.
    #[must_use]
    pub const fn schema(&self) -> &'static str {
        self.schema
    }

    /// Predicates this spec owns, in declaration order.
    #[must_use]
    pub const fn predicates(&self) -> &'static [&'static str] {
        self.predicates
    }

    /// Types this spec owns.
    #[must_use]
    pub const fn types(&self) -> &'static [&'static str] {
        self.types
    }
}
