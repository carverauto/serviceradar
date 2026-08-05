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
use std::time::Duration;

use reqsign_core::time::Timestamp;
use reqsign_core::{Context, Error, ProvideCredential, Result};

use crate::credential::{Credential, Token};

#[derive(Debug, Clone)]
enum TokenSource {
    Inline(String),
    Path(String),
}

#[derive(Debug, Clone, Copy)]
enum Expiration {
    At(Timestamp),
    In(Duration),
}

/// TokenCredentialProvider loads a raw OAuth access token from memory or a file path.
#[derive(Debug, Clone)]
pub struct TokenCredentialProvider {
    source: TokenSource,
    expiration: Option<Expiration>,
}

impl TokenCredentialProvider {
    /// Create a new TokenCredentialProvider from an access token string.
    pub fn new(access_token: impl Into<String>) -> Self {
        Self {
            source: TokenSource::Inline(access_token.into()),
            expiration: None,
        }
    }

    /// Create a new TokenCredentialProvider from a token file path.
    pub fn from_path(path: impl Into<String>) -> Self {
        Self {
            source: TokenSource::Path(path.into()),
            expiration: None,
        }
    }

    /// Set an absolute expiration time for the token.
    pub fn with_expires_at(mut self, expires_at: Timestamp) -> Self {
        self.expiration = Some(Expiration::At(expires_at));
        self
    }

    /// Set a relative expiration duration for the token.
    ///
    /// The expiration is evaluated when credentials are loaded.
    pub fn with_expires_in(mut self, expires_in: Duration) -> Self {
        self.expiration = Some(Expiration::In(expires_in));
        self
    }

    fn build_token(&self, access_token: String) -> Result<Credential> {
        let access_token = access_token.trim().to_string();
        if access_token.is_empty() {
            return Err(Error::credential_invalid("access token is empty"));
        }

        let expires_at = self.expiration.map(|expiration| match expiration {
            Expiration::At(ts) => ts,
            Expiration::In(duration) => Timestamp::now() + duration,
        });

        Ok(Credential::with_token(Token {
            access_token,
            expires_at,
        }))
    }
}

impl ProvideCredential for TokenCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        let access_token = match &self.source {
            TokenSource::Inline(access_token) => {
                debug!("loading access token from static content");
                access_token.clone()
            }
            TokenSource::Path(path) => {
                debug!("loading access token from file path: {path}");
                let content = ctx.file_read(path).await?;
                String::from_utf8(content)
                    .map_err(|e| Error::unexpected("invalid UTF-8 in token file").with_source(e))?
            }
        };

        self.build_token(access_token).map(Some)
    }
}
