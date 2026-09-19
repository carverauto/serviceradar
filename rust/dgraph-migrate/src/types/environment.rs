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

/// Where this run thinks it is.
///
/// Only LOCAL has a default Dgraph host. CI and CLUSTER must be told.
/// An unrecognised value is not an environment: deprovision is refused.
#[derive(Debug, Clone, Copy, Default, Eq, PartialEq)]
pub enum Environment {
    /// Workstation. Host defaults to loopback.
    #[default]
    Local,
    /// CI fixture. Host is required.
    Ci,
    /// Shared / production cluster. Host is required; deprovision needs confirm.
    Cluster,
}

impl Environment {
    /// Parse `LOCAL`, `CI`, or `CLUSTER`. Empty is LOCAL.
    #[must_use]
    pub fn parse(value: Option<&str>) -> Option<Self> {
        match value.map(str::trim).filter(|value| !value.is_empty()) {
            None => Some(Self::Local),
            Some(value) => match value.to_ascii_uppercase().as_str() {
                "LOCAL" => Some(Self::Local),
                "CI" => Some(Self::Ci),
                "CLUSTER" => Some(Self::Cluster),
                _ => None,
            },
        }
    }

    /// Whether this environment may default the Dgraph host to loopback.
    #[must_use]
    pub const fn allows_localhost_default(&self) -> bool {
        matches!(self, Self::Local)
    }

    /// Whether deprovision requires the confirm sentence.
    #[must_use]
    pub const fn deprovision_requires_confirm(&self) -> bool {
        matches!(self, Self::Cluster)
    }
}
