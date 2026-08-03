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

mod env;
pub use env::EnvCredentialProvider;

mod static_provider;
pub use static_provider::StaticCredentialProvider;

mod default;
pub use default::{DefaultCredentialProvider, DefaultCredentialProviderBuilder};

mod imds;
pub use imds::ImdsCredentialProvider;

mod workload_identity;
pub use workload_identity::WorkloadIdentityCredentialProvider;

mod client_secret;
pub use client_secret::ClientSecretCredentialProvider;

#[cfg(not(target_arch = "wasm32"))]
mod azure_cli;
#[cfg(not(target_arch = "wasm32"))]
pub use azure_cli::AzureCliCredentialProvider;

#[cfg(not(target_arch = "wasm32"))]
mod client_certificate;
#[cfg(not(target_arch = "wasm32"))]
pub use client_certificate::ClientCertificateCredentialProvider;

mod azure_pipelines;
pub use azure_pipelines::AzurePipelinesCredentialProvider;
