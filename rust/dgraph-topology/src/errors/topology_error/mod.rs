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

mod topology_error_display;
mod topology_error_error;

/// Why a topology operation failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TopologyError(TopologyErrorEnum);

/// Classification of [`TopologyError`].
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum TopologyErrorEnum {
    /// The cluster could not be reached.
    Connect { target: String, reason: String },
    /// A Dgraph operation failed.
    Dgraph(String),
    /// Response JSON was not the expected shape.
    Serde(String),
    /// A caller value cannot be placed in DQL (quote or newline).
    InvalidValue(String),
    /// Conditional upsert `@if` did not fire: named query block was empty.
    ConditionSkipped { block: String, key: String },
}

impl TopologyError {
    pub(crate) fn new(variant: TopologyErrorEnum) -> Self {
        Self(variant)
    }

    /// Classification, for callers that need to branch on the failure.
    #[must_use]
    pub fn kind(&self) -> &TopologyErrorEnum {
        &self.0
    }

    /// The target is redacted here, not by the caller: this variant reaches the
    /// application log on every failed write and must never carry the ACL
    /// password.
    #[allow(non_snake_case)]
    #[must_use]
    pub fn Connect(target: String, reason: String) -> Self {
        Self::new(TopologyErrorEnum::Connect {
            target: dgraph_migrate::redact_userinfo(&target),
            reason,
        })
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn Dgraph(reason: String) -> Self {
        Self::new(TopologyErrorEnum::Dgraph(reason))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn Serde(reason: String) -> Self {
        Self::new(TopologyErrorEnum::Serde(reason))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn InvalidValue(value: String) -> Self {
        Self::new(TopologyErrorEnum::InvalidValue(value))
    }

    #[allow(non_snake_case)]
    #[must_use]
    pub fn ConditionSkipped(block: String, key: String) -> Self {
        Self::new(TopologyErrorEnum::ConditionSkipped { block, key })
    }
}
