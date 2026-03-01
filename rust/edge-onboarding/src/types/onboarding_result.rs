use crate::DeploymentType;

/// Result of successful edge onboarding.
#[derive(Debug)]
pub struct OnboardingResult {
    /// Path to the generated configuration file.
    pub config_path: String,

    /// Raw configuration data.
    pub config_data: Vec<u8>,

    /// Assigned SPIFFE ID (if using SPIRE).
    pub spiffe_id: Option<String>,

    /// Package ID from the onboarding token.
    pub package_id: String,

    /// Deployment type detected.
    pub deployment_type: DeploymentType,

    /// Directory where certificates are installed.
    pub cert_dir: String,
}