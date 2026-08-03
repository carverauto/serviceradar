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

use crate::constants::{DEFAULT_SCOPE, GOOGLE_SCOPE};
use crate::credential::{Credential, CredentialFile};

use super::{
    authorized_user::AuthorizedUserCredentialProvider,
    external_account::ExternalAccountCredentialProvider,
    impersonated_service_account::ImpersonatedServiceAccountCredentialProvider,
};

pub(super) async fn parse_credential_bytes(
    ctx: &Context,
    content: &[u8],
    scope_override: Option<String>,
) -> Result<Option<Credential>> {
    let cred_file = CredentialFile::from_slice(content)?;

    let scope = scope_override
        .or_else(|| ctx.env_var(GOOGLE_SCOPE))
        .unwrap_or_else(|| DEFAULT_SCOPE.to_string());

    match cred_file {
        CredentialFile::ServiceAccount(sa) => {
            debug!("loaded service account credential");
            Ok(Some(Credential::with_service_account(sa)))
        }
        CredentialFile::ExternalAccount(ea) => {
            debug!("loaded external account credential, exchanging for token");
            let provider = ExternalAccountCredentialProvider::new(ea).with_scope(&scope);
            provider.provide_credential(ctx).await
        }
        CredentialFile::ImpersonatedServiceAccount(isa) => {
            debug!("loaded impersonated service account credential, exchanging for token");
            let provider =
                ImpersonatedServiceAccountCredentialProvider::new(isa).with_scope(&scope);
            provider.provide_credential(ctx).await
        }
        CredentialFile::AuthorizedUser(au) => {
            debug!("loaded authorized user credential, exchanging for token");
            let provider = AuthorizedUserCredentialProvider::new(au);
            provider.provide_credential(ctx).await
        }
    }
}
