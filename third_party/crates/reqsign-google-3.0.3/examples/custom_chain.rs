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

//! Example of building a custom credential chain with specific providers
use reqsign_core::{Context, ProvideCredential, ProvideCredentialChain, Result};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_google::{Credential, ServiceAccount, Token};
use reqsign_http_send_reqwest::ReqwestHttpSend;

/// Custom provider that always returns a specific credential
#[derive(Debug)]
struct StaticCredentialProvider {
    credential: Credential,
}

impl StaticCredentialProvider {
    fn new_with_service_account(client_email: String, private_key: String) -> Self {
        Self {
            credential: Credential::with_service_account(ServiceAccount {
                client_email,
                private_key,
            }),
        }
    }

    fn new_with_token(access_token: String) -> Self {
        Self {
            credential: Credential::with_token(Token {
                access_token,
                expires_at: None,
            }),
        }
    }
}
impl ProvideCredential for StaticCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, _ctx: &Context) -> Result<Option<Self::Credential>> {
        Ok(Some(self.credential.clone()))
    }
}

/// Environment-based provider (simplified example)
#[derive(Debug)]
struct EnvCredentialProvider;
impl ProvideCredential for EnvCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        // Check for service account in environment
        if let (Some(email), Some(key)) = (
            ctx.env_var("GOOGLE_CLIENT_EMAIL"),
            ctx.env_var("GOOGLE_PRIVATE_KEY"),
        ) {
            return Ok(Some(Credential::with_service_account(ServiceAccount {
                client_email: email,
                private_key: key,
            })));
        }

        // Check for access token in environment
        if let Some(token) = ctx.env_var("GOOGLE_ACCESS_TOKEN") {
            return Ok(Some(Credential::with_token(Token {
                access_token: token,
                expires_at: None,
            })));
        }

        Ok(None)
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    // Create context
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default());

    // Build a custom chain with specific priority order
    let chain = ProvideCredentialChain::new()
        // First, try environment variables
        .push(EnvCredentialProvider)
        // Then try a static credential (for development/testing)
        .push(StaticCredentialProvider::new_with_service_account(
            "dev@example.iam.gserviceaccount.com".to_string(),
            "fake_private_key_for_development".to_string(),
        ));

    // You can also build chains dynamically based on configuration
    let mut dynamic_chain = ProvideCredentialChain::new();

    if std::env::var("USE_ENV_CREDS").is_ok() {
        dynamic_chain = dynamic_chain.push(EnvCredentialProvider);
    }

    if std::env::var("USE_STATIC_TOKEN").is_ok() {
        dynamic_chain = dynamic_chain.push(StaticCredentialProvider::new_with_token(
            "static_access_token".to_string(),
        ));
    }

    // Example of using the dynamic chain
    println!("\nDynamic chain resolution:");
    match dynamic_chain.provide_credential(&ctx).await? {
        Some(_) => println!("Found credential in dynamic chain"),
        None => println!("No credentials in dynamic chain"),
    }

    // Resolve credentials from the chain
    match chain.provide_credential(&ctx).await? {
        Some(cred) => {
            println!("Found credential!");
            if let Some(sa) = &cred.service_account {
                println!("Using service account: {}", sa.client_email);
            }
            if cred.has_token() {
                println!("Using access token");
            }
        }
        None => {
            println!("No credentials found");
        }
    }

    Ok(())
}
