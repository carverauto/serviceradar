use thiserror::Error;

#[derive(Error, Debug)]
pub enum CredentialsError {
    #[error("Not an AWS instance")]
    NotEc2,
    #[error("Not a container")]
    NotContainer,
    #[error("Config not found")]
    ConfigNotFound,
    #[error("Missing aws_access_key_id section in config")]
    ConfigMissingAccessKeyId,
    #[error("Missing aws_access_key_id section in config")]
    ConfigMissingSecretKey,
    #[error("Neither {0}, nor {1} exists in the environment")]
    MissingEnvVar(String, String),
    #[cfg(feature = "http-credentials")]
    #[error("attohttpc: {0}")]
    Atto(#[from] attohttpc::Error),
    #[error("ini: {0}")]
    Ini(#[from] ini::Error),
    #[error("serde_xml: {0}")]
    SerdeXml(#[from] quick_xml::de::DeError),
    #[error("url parse: {0}")]
    UrlParse(#[from] url::ParseError),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("env var: {0}")]
    Env(#[from] std::env::VarError),
    #[error("Invalid home dir")]
    HomeDir,
    #[error("Could not get valid credentials from STS, ENV, Profile or Instance metadata")]
    NoCredentials,
    #[error("unexpected status code: {0}")]
    UnexpectedStatusCode(u16),
}
