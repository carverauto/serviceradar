/// Configuration for mTLS bootstrap.
#[derive(Debug, Clone)]
pub struct MtlsBootstrapConfig {
    /// The edgepkg-v1 token containing package ID and download token.
    pub token: String,

    /// Core API host for mTLS bundle download (e.g., http://core:8090).
    /// Used as fallback if the token doesn't contain an API URL.
    pub host: Option<String>,

    /// Optional path to a pre-fetched mTLS bundle.
    pub bundle_path: Option<String>,

    /// Directory to write mTLS certificates. Defaults to /etc/serviceradar/certs.
    pub cert_dir: Option<String>,

    /// Service name (used for cert file naming). Defaults to "sysmon".
    pub service_name: Option<String>,
}