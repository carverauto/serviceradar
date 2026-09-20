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

use std::path::Path;

use crate::{CanonicalEdgeRecord, MigratorError, Mode};

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct DumpFile {
    #[serde(default)]
    pub nodes: u64,
    pub edges: Vec<CanonicalEdgeRecord>,
}

/// Load a synthetic lab dump. Live captures must never be committed.
pub fn load_dump(path: &Path) -> Result<DumpFile, MigratorError> {
    Mode::require_lab_dump_allowed()?;
    let bytes = std::fs::read(path).map_err(|err| MigratorError::Io(err.to_string()))?;
    parse_dump(&bytes)
}

pub fn parse_dump(bytes: &[u8]) -> Result<DumpFile, MigratorError> {
    serde_json::from_slice(bytes).map_err(|err| MigratorError::Io(err.to_string()))
}
