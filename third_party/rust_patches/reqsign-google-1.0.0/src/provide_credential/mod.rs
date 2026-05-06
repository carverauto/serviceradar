mod default;
pub use default::DefaultCredentialProvider;

mod vm_metadata;
pub use vm_metadata::VmMetadataCredentialProvider;

mod static_provider;
pub use static_provider::StaticCredentialProvider;

// Internal providers - not exported
mod authorized_user;
mod external_account;
mod impersonated_service_account;
