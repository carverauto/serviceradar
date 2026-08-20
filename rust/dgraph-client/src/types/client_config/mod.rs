/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

mod client_config_debug;

use crate::errors::connect_error::ConnectError;
use crate::errors::connection_string_error::ConnectionStringError;
use crate::types::ca_certificate::CaCertificate;
use crate::types::connection_string::ConnectionString;
use crate::types::secret::Secret;
use crate::types::tls_mode::TlsMode;

/// How a client connects to a Dgraph cluster.
///
/// Build with [`ClientConfig::builder`], or from a `dgraph://` connection string with
/// [`ClientConfig::from_connection_string`].
///
/// `Debug` is hand-written and redacts every credential.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct ClientConfig {
    endpoints: Vec<String>,
    tls: TlsMode,
    username: Option<String>,
    password: Option<Secret>,
    api_key: Option<Secret>,
    bearer_token: Option<Secret>,
    namespace: Option<u64>,
    ca_certificate: Option<CaCertificate>,
}

impl ClientConfig {
    /// Start building a configuration for the given endpoints.
    pub fn builder() -> ClientConfigBuilder {
        ClientConfigBuilder::default()
    }

    /// Build a configuration from a single `dgraph://` connection string.
    pub fn from_connection_string(input: &str) -> Result<Self, ConnectionStringError> {
        let parsed = ConnectionString::parse(input)?;
        Ok(Self::from_parsed_connection_string(&parsed))
    }

    /// Build a configuration from an already-parsed connection string.
    pub fn from_parsed_connection_string(parsed: &ConnectionString) -> Self {
        Self {
            endpoints: vec![parsed.authority()],
            tls: parsed.tls_mode(),
            username: parsed.username().map(str::to_string),
            password: parsed.password().cloned(),
            api_key: parsed.api_key().cloned(),
            bearer_token: parsed.bearer_token().cloned(),
            namespace: parsed.namespace(),
            ca_certificate: parsed
                .ca_cert_path()
                .map(|path| CaCertificate::File(path.to_path_buf())),
        }
    }

    /// Endpoints this client will round-robin across. Never empty.
    pub fn endpoints(&self) -> &[String] {
        &self.endpoints
    }

    pub fn tls_mode(&self) -> TlsMode {
        self.tls
    }

    pub fn username(&self) -> Option<&str> {
        self.username.as_deref()
    }

    pub fn password(&self) -> Option<&Secret> {
        self.password.as_ref()
    }

    pub fn api_key(&self) -> Option<&Secret> {
        self.api_key.as_ref()
    }

    pub fn bearer_token(&self) -> Option<&Secret> {
        self.bearer_token.as_ref()
    }

    pub fn namespace(&self) -> Option<u64> {
        self.namespace
    }

    /// Certificate authority to verify the server against, replacing the system trust store.
    pub fn ca_certificate(&self) -> Option<&CaCertificate> {
        self.ca_certificate.as_ref()
    }

    /// Whether ACL credentials were supplied, meaning the client should log in on connect.
    pub fn has_acl_credentials(&self) -> bool {
        self.username.is_some() && self.password.is_some()
    }
}

/// Builder for [`ClientConfig`].
#[derive(Debug, Default, Clone)]
pub struct ClientConfigBuilder {
    endpoints: Vec<String>,
    tls: TlsMode,
    username: Option<String>,
    password: Option<Secret>,
    api_key: Option<Secret>,
    bearer_token: Option<Secret>,
    namespace: Option<u64>,
    ca_certificate: Option<CaCertificate>,
}

impl ClientConfigBuilder {
    /// Add one endpoint, as a `host:port` authority.
    pub fn endpoint(mut self, endpoint: impl Into<String>) -> Self {
        self.endpoints.push(endpoint.into());
        self
    }

    /// Add several endpoints to round-robin across.
    pub fn endpoints<I, S>(mut self, endpoints: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.endpoints.extend(endpoints.into_iter().map(Into::into));
        self
    }

    pub fn tls_mode(mut self, tls: TlsMode) -> Self {
        self.tls = tls;
        self
    }

    /// ACL credentials. The client logs in with these when connecting.
    pub fn acl_credentials(mut self, username: impl Into<String>, password: Secret) -> Self {
        self.username = Some(username.into());
        self.password = Some(password);
        self
    }

    pub fn api_key(mut self, api_key: Secret) -> Self {
        self.api_key = Some(api_key);
        self
    }

    pub fn bearer_token(mut self, token: Secret) -> Self {
        self.bearer_token = Some(token);
        self
    }

    pub fn namespace(mut self, namespace: u64) -> Self {
        self.namespace = Some(namespace);
        self
    }

    /// Verify the server against this certificate authority rather than the system trust
    /// store. Takes the PEM directly, for callers that already hold it -- a CA resolved
    /// through SecretManager arrives as content, never as a path.
    pub fn ca_certificate(mut self, ca: CaCertificate) -> Self {
        self.ca_certificate = Some(ca);
        self
    }

    /// Finish the configuration.
    ///
    /// Rejects an empty endpoint list. The Go client accepts one and then panics later in
    /// `rand.Intn(0)` when it first tries to pick a connection; validating here means that
    /// panic has no reachable equivalent.
    pub fn build(self) -> Result<ClientConfig, ConnectError> {
        if self.endpoints.is_empty() {
            return Err(ConnectError::NoEndpoints());
        }

        Ok(ClientConfig {
            endpoints: self.endpoints,
            tls: self.tls,
            username: self.username,
            password: self.password,
            api_key: self.api_key,
            bearer_token: self.bearer_token,
            namespace: self.namespace,
            ca_certificate: self.ca_certificate,
        })
    }
}
