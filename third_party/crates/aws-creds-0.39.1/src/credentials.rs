#![allow(dead_code)]

use crate::error::CredentialsError;
use ini::Ini;
use log::debug;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::env;
use std::ops::Deref;
use std::path::Path;
use std::sync::atomic::AtomicU32;
use std::sync::atomic::Ordering;
use std::time::Duration;
use time::OffsetDateTime;
use url::Url;

/// AWS access credentials: access key, secret key, and optional token.
///
/// # Example
///
/// Loads from the standard AWS credentials file with the given profile name,
/// defaults to "default".
///
/// ```no_run
/// # // Do not execute this as it would cause unit tests to attempt to access
/// # // real user credentials.
/// use awscreds::Credentials;
///
/// // Load credentials from `[default]` profile
/// let credentials = Credentials::default();
///
/// // Also loads credentials from `[default]` profile
/// let credentials = Credentials::new(None, None, None, None, None);
///
/// // Load credentials from `[my-profile]` profile
/// let credentials = Credentials::new(None, None, None, None, Some("my-profile".into()));
///
/// // Use anonymous credentials for public objects
/// let credentials = Credentials::anonymous();
/// ```
///
/// Credentials may also be initialized directly or by the following environment variables:
///
///   - `AWS_ACCESS_KEY_ID`,
///   - `AWS_SECRET_ACCESS_KEY`
///   - `AWS_SESSION_TOKEN`
///
/// The order of preference is arguments, then environment, and finally AWS
/// credentials file.
///
/// ```
/// use awscreds::Credentials;
///
/// // Load credentials directly
/// let access_key = "AKIAIOSFODNN7EXAMPLE";
/// let secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
/// let credentials = Credentials::new(Some(access_key), Some(secret_key), None, None, None);
///
/// // Load credentials from the environment
/// use std::env;
/// env::set_var("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE");
/// env::set_var("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
/// let credentials = Credentials::new(None, None, None, None, None);
/// ```
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Credentials {
    /// AWS public access key.
    pub access_key: Option<String>,
    /// AWS secret key.
    pub secret_key: Option<String>,
    /// Temporary token issued by AWS service.
    pub security_token: Option<String>,
    pub session_token: Option<String>,
    pub expiration: Option<Rfc3339OffsetDateTime>,
}

#[derive(Debug, Copy, Clone, Eq, PartialEq, Serialize, Deserialize)]
#[repr(transparent)]
pub struct Rfc3339OffsetDateTime(#[serde(with = "time::serde::rfc3339")] pub time::OffsetDateTime);

impl From<time::OffsetDateTime> for Rfc3339OffsetDateTime {
    fn from(v: time::OffsetDateTime) -> Self {
        Self(v)
    }
}

impl From<Rfc3339OffsetDateTime> for time::OffsetDateTime {
    fn from(v: Rfc3339OffsetDateTime) -> Self {
        v.0
    }
}

impl Deref for Rfc3339OffsetDateTime {
    type Target = time::OffsetDateTime;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "PascalCase")]
pub struct AssumeRoleWithWebIdentityResponse {
    pub assume_role_with_web_identity_result: AssumeRoleWithWebIdentityResult,
    pub response_metadata: ResponseMetadata,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "PascalCase")]
pub struct AssumeRoleWithWebIdentityResult {
    pub subject_from_web_identity_token: String,
    pub audience: String,
    pub assumed_role_user: AssumedRoleUser,
    pub credentials: StsResponseCredentials,
    pub provider: String,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "PascalCase")]
pub struct StsResponseCredentials {
    pub session_token: String,
    pub secret_access_key: String,
    pub expiration: Rfc3339OffsetDateTime,
    pub access_key_id: String,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "PascalCase")]
pub struct AssumedRoleUser {
    pub arn: String,
    pub assumed_role_id: String,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "PascalCase")]
pub struct ResponseMetadata {
    pub request_id: String,
}

/// The global request timeout in milliseconds. 0 means no timeout.
///
/// Defaults to 30 seconds.
static REQUEST_TIMEOUT_MS: AtomicU32 = AtomicU32::new(30_000);

/// Sets the timeout for all credentials HTTP requests and returns the
/// old timeout value, if any; this timeout applies after a 30-second
/// connection timeout.
///
/// Short durations are bumped to one millisecond, and durations
/// greater than 4 billion milliseconds (49 days) are rounded up to
/// infinity (no timeout).
/// The global default value is 30 seconds.
#[cfg(feature = "http-credentials")]
pub fn set_request_timeout(timeout: Option<Duration>) -> Option<Duration> {
    use std::convert::TryInto;
    let duration_ms = timeout
        .as_ref()
        .map(Duration::as_millis)
        .unwrap_or(u128::MAX)
        .max(1); // A 0 duration means infinity.

    // Store that non-zero u128 value in an AtomicU32 by mapping large
    // values to 0: `http_get` maps that to no (infinite) timeout.
    let prev = REQUEST_TIMEOUT_MS.swap(duration_ms.try_into().unwrap_or(0), Ordering::Relaxed);

    if prev == 0 {
        None
    } else {
        Some(Duration::from_millis(prev as u64))
    }
}

#[cfg(feature = "http-credentials")]
fn apply_timeout(builder: attohttpc::RequestBuilder) -> attohttpc::RequestBuilder {
    let timeout_ms = REQUEST_TIMEOUT_MS.load(Ordering::Relaxed);
    if timeout_ms > 0 {
        return builder.timeout(Duration::from_millis(timeout_ms as u64));
    }
    builder
}

/// Sends a GET request to `url` with a request timeout if one was set.
#[cfg(feature = "http-credentials")]
fn http_get(url: &str) -> attohttpc::Result<attohttpc::Response> {
    let builder = apply_timeout(attohttpc::get(url));

    builder.send()
}

impl Credentials {
    pub fn refresh(&mut self) -> Result<(), CredentialsError> {
        if let Some(expiration) = self.expiration {
            if expiration.0 <= OffsetDateTime::now_utc() {
                debug!("Refreshing credentials!");
                let refreshed = Credentials::default()?;
                *self = refreshed
            }
        }
        Ok(())
    }

    #[cfg(feature = "http-credentials")]
    pub fn from_sts_env(session_name: &str) -> Result<Credentials, CredentialsError> {
        let role_arn = env::var("AWS_ROLE_ARN")?;
        let web_identity_token_file = env::var("AWS_WEB_IDENTITY_TOKEN_FILE")?;
        let web_identity_token = std::fs::read_to_string(web_identity_token_file)?;
        Credentials::from_sts(&role_arn, session_name, &web_identity_token)
    }

    #[cfg(feature = "http-credentials")]
    pub fn from_sts(
        role_arn: &str,
        session_name: &str,
        web_identity_token: &str,
    ) -> Result<Credentials, CredentialsError> {
        let url = Url::parse_with_params(
            "https://sts.amazonaws.com/",
            &[
                ("Action", "AssumeRoleWithWebIdentity"),
                ("RoleSessionName", session_name),
                ("RoleArn", role_arn),
                ("WebIdentityToken", web_identity_token),
                ("Version", "2011-06-15"),
            ],
        )?;
        let response = http_get(url.as_str())?;
        let serde_response =
            quick_xml::de::from_str::<AssumeRoleWithWebIdentityResponse>(&response.text()?)?;
        // assert!(quick_xml::de::from_str::<AssumeRoleWithWebIdentityResponse>(&response.text()?).unwrap());

        Ok(Credentials {
            access_key: Some(
                serde_response
                    .assume_role_with_web_identity_result
                    .credentials
                    .access_key_id,
            ),
            secret_key: Some(
                serde_response
                    .assume_role_with_web_identity_result
                    .credentials
                    .secret_access_key,
            ),
            security_token: None,
            session_token: Some(
                serde_response
                    .assume_role_with_web_identity_result
                    .credentials
                    .session_token,
            ),
            expiration: Some(
                serde_response
                    .assume_role_with_web_identity_result
                    .credentials
                    .expiration,
            ),
        })
    }

    #[allow(clippy::should_implement_trait)]
    pub fn default() -> Result<Credentials, CredentialsError> {
        Credentials::new(None, None, None, None, None)
    }

    pub fn anonymous() -> Result<Credentials, CredentialsError> {
        Ok(Credentials {
            access_key: None,
            secret_key: None,
            security_token: None,
            session_token: None,
            expiration: None,
        })
    }

    /// Initialize Credentials directly with key ID, secret key, and optional
    /// token.
    pub fn new(
        access_key: Option<&str>,
        secret_key: Option<&str>,
        security_token: Option<&str>,
        session_token: Option<&str>,
        profile: Option<&str>,
    ) -> Result<Credentials, CredentialsError> {
        if access_key.is_some() {
            return Ok(Credentials {
                access_key: access_key.map(|s| s.to_string()),
                secret_key: secret_key.map(|s| s.to_string()),
                security_token: security_token.map(|s| s.to_string()),
                session_token: session_token.map(|s| s.to_string()),
                expiration: None,
            });
        }

        let credentials = Credentials::from_env().or_else(|_| Credentials::from_profile(profile));

        #[cfg(feature = "http-credentials")]
        let credentials = credentials
            .or_else(|_| Credentials::from_sts_env("aws-creds"))
            .or_else(|_| Credentials::from_container_credentials_provider())
            .or_else(|_| Credentials::from_instance_metadata_v2(false))
            .or_else(|_| Credentials::from_instance_metadata(false));

        credentials.map_err(|_| CredentialsError::NoCredentials)
    }

    pub fn from_env_specific(
        access_key_var: Option<&str>,
        secret_key_var: Option<&str>,
        security_token_var: Option<&str>,
        session_token_var: Option<&str>,
    ) -> Result<Credentials, CredentialsError> {
        let access_key = from_env_with_default(access_key_var, "AWS_ACCESS_KEY_ID")?;
        let secret_key = from_env_with_default(secret_key_var, "AWS_SECRET_ACCESS_KEY")?;

        let security_token = from_env_with_default(security_token_var, "AWS_SECURITY_TOKEN").ok();
        let session_token = from_env_with_default(session_token_var, "AWS_SESSION_TOKEN").ok();
        Ok(Credentials {
            access_key: Some(access_key),
            secret_key: Some(secret_key),
            security_token,
            session_token,
            expiration: None,
        })
    }

    pub fn from_env() -> Result<Credentials, CredentialsError> {
        Credentials::from_env_specific(None, None, None, None)
    }

    #[cfg(feature = "http-credentials")]
    pub fn from_container_credentials_provider() -> Result<Credentials, CredentialsError> {
        let Ok(credentials_path) = env::var("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI") else {
            return Err(CredentialsError::NotContainer);
        };

        let resp: CredentialsFromInstanceMetadata = apply_timeout(attohttpc::get(format!(
            "http://169.254.170.2{}",
            credentials_path
        )))
        .send()?
        .json()?;

        Ok(Credentials {
            access_key: Some(resp.access_key_id),
            secret_key: Some(resp.secret_access_key),
            security_token: Some(resp.token),
            expiration: Some(resp.expiration),
            session_token: None,
        })
    }

    #[cfg(feature = "http-credentials")]
    pub fn from_instance_metadata(not_ec2: bool) -> Result<Credentials, CredentialsError> {
        if !not_ec2 && !is_ec2() {
            return Err(CredentialsError::NotEc2);
        }

        let role = apply_timeout(attohttpc::get(
            "http://169.254.169.254/latest/meta-data/iam/security-credentials",
        ))
        .send()?
        .text()?;

        let resp: CredentialsFromInstanceMetadata = apply_timeout(attohttpc::get(format!(
            "http://169.254.169.254/latest/meta-data/iam/security-credentials/{}",
            role
        )))
        .send()?
        .json()?;

        Ok(Credentials {
            access_key: Some(resp.access_key_id),
            secret_key: Some(resp.secret_access_key),
            security_token: Some(resp.token),
            expiration: Some(resp.expiration),
            session_token: None,
        })
    }

    #[cfg(feature = "http-credentials")]
    pub fn from_instance_metadata_v2(not_ec2: bool) -> Result<Credentials, CredentialsError> {
        if !not_ec2 && !is_ec2() {
            return Err(CredentialsError::NotEc2);
        }

        let token = apply_timeout(attohttpc::put("http://169.254.169.254/latest/api/token"))
            .header("X-aws-ec2-metadata-token-ttl-seconds", "21600")
            .send()?;
        if !token.is_success() {
            return Err(CredentialsError::UnexpectedStatusCode(
                token.status().as_u16(),
            ));
        }
        let token = token.text()?;

        let role = apply_timeout(attohttpc::get(
            "http://169.254.169.254/latest/meta-data/iam/security-credentials",
        ))
        .header("X-aws-ec2-metadata-token", &token)
        .send()?
        .text()?;

        let resp: CredentialsFromInstanceMetadata = apply_timeout(attohttpc::get(format!(
            "http://169.254.169.254/latest/meta-data/iam/security-credentials/{}",
            role
        )))
        .header("X-aws-ec2-metadata-token", &token)
        .send()?
        .json()?;

        Ok(Credentials {
            access_key: Some(resp.access_key_id),
            secret_key: Some(resp.secret_access_key),
            security_token: Some(resp.token),
            expiration: Some(resp.expiration),
            session_token: None,
        })
    }

    /// Load credentials from a specific credentials file.
    ///
    /// This method allows loading AWS credentials from a custom file location,
    /// which is useful when credentials are stored in a non-standard location.
    ///
    /// # Arguments
    ///
    /// * `file` - Path to the credentials file
    /// * `section` - Optional profile name to load (defaults to "default")
    ///
    /// # Example
    ///
    /// ```no_run
    /// use awscreds::Credentials;
    ///
    /// let credentials = Credentials::from_credentials_file(
    ///     "/custom/path/credentials",
    ///     Some("production")
    /// ).unwrap();
    /// ```
    pub fn from_credentials_file<P: AsRef<Path>>(
        file: P,
        section: Option<&str>,
    ) -> Result<Credentials, CredentialsError> {
        let conf = Ini::load_from_file(file.as_ref())?;
        let section = section.unwrap_or("default");
        let data = conf
            .section(Some(section))
            .ok_or(CredentialsError::ConfigNotFound)?;
        let access_key = data
            .get("aws_access_key_id")
            .map(|s| s.to_string())
            .ok_or(CredentialsError::ConfigMissingAccessKeyId)?;
        let secret_key = data
            .get("aws_secret_access_key")
            .map(|s| s.to_string())
            .ok_or(CredentialsError::ConfigMissingSecretKey)?;
        let credentials = Credentials {
            access_key: Some(access_key),
            secret_key: Some(secret_key),
            security_token: data.get("aws_security_token").map(|s| s.to_string()),
            session_token: data.get("aws_session_token").map(|s| s.to_string()),
            expiration: None,
        };
        Ok(credentials)
    }

    pub fn from_profile(section: Option<&str>) -> Result<Credentials, CredentialsError> {
        // Check for AWS_SHARED_CREDENTIALS_FILE environment variable first
        let profile = if let Ok(path) = env::var("AWS_SHARED_CREDENTIALS_FILE") {
            path
        } else {
            let home_dir = home::home_dir().ok_or(CredentialsError::HomeDir)?;
            format!("{}/.aws/credentials", home_dir.display())
        };
        Credentials::from_credentials_file(&profile, section)
    }
}

fn from_env_with_default(var: Option<&str>, default: &str) -> Result<String, CredentialsError> {
    let val = var.unwrap_or(default);
    env::var(val)
        .or_else(|_e| env::var(val))
        .map_err(|_| CredentialsError::MissingEnvVar(val.to_string(), default.to_string()))
}

fn is_ec2() -> bool {
    if let Ok(uuid) = std::fs::read_to_string("/sys/hypervisor/uuid") {
        if uuid.starts_with("ec2") {
            return true;
        }
    }
    if let Ok(vendor) = std::fs::read_to_string("/sys/class/dmi/id/board_vendor") {
        if vendor.starts_with("Amazon EC2") {
            return true;
        }
    }
    false
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct CredentialsFromInstanceMetadata {
    access_key_id: String,
    secret_access_key: String,
    token: String,
    expiration: Rfc3339OffsetDateTime, // TODO fix #163
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn create_test_credentials_file(content: &str) -> NamedTempFile {
        let mut file = NamedTempFile::new().unwrap();
        file.write_all(content.as_bytes()).unwrap();
        file.flush().unwrap();
        file
    }

    #[test]
    fn test_from_credentials_file_custom_location() {
        let content = r#"[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

[production]
aws_access_key_id = PROD_KEY
aws_secret_access_key = PROD_SECRET
aws_session_token = PROD_SESSION_TOKEN
"#;
        let file = create_test_credentials_file(content);

        // Test default section
        let creds = Credentials::from_credentials_file(file.path(), None).unwrap();
        assert_eq!(creds.access_key.unwrap(), "AKIAIOSFODNN7EXAMPLE");

        // Test custom section
        let creds = Credentials::from_credentials_file(file.path(), Some("production")).unwrap();
        assert_eq!(creds.access_key.unwrap(), "PROD_KEY");
        assert_eq!(creds.session_token.unwrap(), "PROD_SESSION_TOKEN");
    }

    #[test]
    fn test_from_profile_respects_env_var() {
        let content = r#"[default]
aws_access_key_id = ENV_KEY
aws_secret_access_key = ENV_SECRET
"#;
        let file = create_test_credentials_file(content);

        // Set the environment variable
        env::set_var("AWS_SHARED_CREDENTIALS_FILE", file.path());

        let creds = Credentials::from_profile(None).unwrap();
        assert_eq!(creds.access_key.unwrap(), "ENV_KEY");

        // Clean up
        env::remove_var("AWS_SHARED_CREDENTIALS_FILE");
    }

    #[test]
    fn test_from_credentials_file_errors() {
        // Test missing file
        let result = Credentials::from_credentials_file("/nonexistent/path", None);
        assert!(result.is_err());

        // Test missing section
        let content = r#"[default]
aws_access_key_id = KEY
aws_secret_access_key = SECRET
"#;
        let file = create_test_credentials_file(content);
        let result = Credentials::from_credentials_file(file.path(), Some("nonexistent"));
        assert!(matches!(
            result.unwrap_err(),
            CredentialsError::ConfigNotFound
        ));
    }
}

#[cfg(test)]
#[test]
fn test_instance_metadata_creds_deserialization() {
    // As documented here:
    // https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html#instance-metadata-security-credentials
    serde_json::from_str::<CredentialsFromInstanceMetadata>(
        r#"
        {
            "Code" : "Success",
            "LastUpdated" : "2012-04-26T16:39:16Z",
            "Type" : "AWS-HMAC",
            "AccessKeyId" : "ASIAIOSFODNN7EXAMPLE",
            "SecretAccessKey" : "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "Token" : "token",
            "Expiration" : "2017-05-17T15:09:54Z"
        }
    "#,
    )
    .unwrap();
}

#[cfg(test)]
#[ignore]
#[test]
fn test_credentials_refresh() {
    let mut c = Credentials::default().expect("Could not generate credentials");
    let e = Rfc3339OffsetDateTime(OffsetDateTime::now_utc());
    c.expiration = Some(e);
    std::thread::sleep(std::time::Duration::from_secs(3));
    c.refresh().expect("Could not refresh");
    assert!(c.expiration.is_none())
}
