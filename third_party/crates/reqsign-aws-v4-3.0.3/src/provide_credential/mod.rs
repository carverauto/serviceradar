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

mod assume_role;
pub use assume_role::AssumeRoleCredentialProvider;

mod assume_role_with_web_identity;
pub use assume_role_with_web_identity::AssumeRoleWithWebIdentityCredentialProvider;

mod cognito;
pub use cognito::CognitoIdentityCredentialProvider;

mod default;
pub use default::{DefaultCredentialProvider, DefaultCredentialProviderBuilder};

mod ecs;
pub use ecs::ECSCredentialProvider;

mod env;
pub use env::EnvCredentialProvider;

mod imds;
pub use imds::IMDSv2CredentialProvider;

#[cfg(not(target_arch = "wasm32"))]
mod process;
#[cfg(not(target_arch = "wasm32"))]
pub use process::ProcessCredentialProvider;

mod profile;
pub use profile::ProfileCredentialProvider;

#[cfg(not(target_arch = "wasm32"))]
mod sso;
#[cfg(not(target_arch = "wasm32"))]
pub use sso::SSOCredentialProvider;

mod r#static;
pub use r#static::StaticCredentialProvider;

mod s3_express_session;
pub use s3_express_session::S3ExpressSessionProvider;

mod utils;
