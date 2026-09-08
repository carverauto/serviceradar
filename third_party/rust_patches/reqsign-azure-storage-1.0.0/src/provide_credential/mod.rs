mod env;
pub use env::EnvCredentialProvider;

mod static_provider;
pub use static_provider::StaticCredentialProvider;

mod default;
pub use default::DefaultCredentialProvider;

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
