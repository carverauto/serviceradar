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

use std::fmt::{Display, Formatter};

use super::{TopologyError, TopologyErrorEnum};

impl Display for TopologyError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match &self.0 {
            TopologyErrorEnum::Connect { target, reason } => {
                write!(f, "connect to {target}: {reason}")
            }
            TopologyErrorEnum::Dgraph(reason) => write!(f, "dgraph: {reason}"),
            TopologyErrorEnum::Serde(reason) => write!(f, "decode dgraph response: {reason}"),
            TopologyErrorEnum::InvalidValue(value) => {
                write!(f, "value cannot be placed in DQL: {value}")
            }
            TopologyErrorEnum::ConditionSkipped { block, key } => {
                write!(f, "upsert @if skipped: {block} empty for {key}")
            }
        }
    }
}
