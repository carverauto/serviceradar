// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

use log::debug;

use reqsign_core::{Context, ProvideCredential, Result};

use crate::credential::Credential;

use super::parse::parse_credential_bytes;

/// FileCredentialProvider loads Google credentials from an explicit credential file path.
#[derive(Debug, Clone)]
pub struct FileCredentialProvider {
    path: String,
    scope: Option<String>,
}

impl FileCredentialProvider {
    /// Create a new FileCredentialProvider from a credential file path.
    pub fn new(path: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            scope: None,
        }
    }

    /// Set the OAuth2 scope.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }
}

impl ProvideCredential for FileCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        debug!("loading credential from file path: {}", self.path);

        let content = ctx.file_read(&self.path).await?;
        parse_credential_bytes(ctx, &content, self.scope.clone()).await
    }
}
