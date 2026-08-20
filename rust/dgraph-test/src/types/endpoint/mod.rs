//! The Dgraph endpoint, resolved through the auto-config system.

use crate::errors::fixture_error::FixtureError;
use serviceradar_config_manager::{ConfigManager, Filesystem, Identity, built_ins};
use serviceradar_config_schema::DgraphTlsMode;

/// Dgraph's admin HTTP port. Fixed by Dgraph, and absent from the configuration because the
/// configuration describes the gRPC endpoint a client connects to, not an admin port nothing
/// connects to.
pub const HTTP_PORT: u16 = 8080;

/// Where Dgraph is, and what transport security it expects.
///
/// Read rather than restated: the committed instance is the single description of the endpoint,
/// so a disagreement between it and reality fails a test instead of passing against a private
/// copy that has drifted.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Endpoint {
    host: String,
    port: u16,
    tls_mode: DgraphTlsMode,
}

impl Endpoint {
    /// The production resolution path: identity from the environment, instance from
    /// `ConfigManager`. There is no test-only constructor, so a change that breaks real callers
    /// breaks this too.
    pub fn from_config(identity: &Identity) -> Result<Self, FixtureError> {
        let manager = ConfigManager::load(identity, built_ins(), &Filesystem).map_err(|err| {
            FixtureError::configuration(format!(
                "loading the '{}' instance failed: {err}",
                identity.kind()
            ))
        })?;

        let dgraph = manager.dgraph().ok_or_else(|| {
            FixtureError::configuration(format!(
                "the '{}' instance declares no dgraph section",
                identity.kind()
            ))
        })?;

        let host = dgraph
            .host
            .clone()
            .ok_or_else(|| FixtureError::configuration("dgraph.host is unset"))?;
        let port = dgraph
            .port
            .ok_or_else(|| FixtureError::configuration("dgraph.port is unset"))?;
        let port = u16::try_from(port).map_err(|_| {
            FixtureError::configuration(format!("dgraph.port {port} is not a port number"))
        })?;
        // The typed posture, not a string: an unknown discriminant is an error here rather than
        // a silent fall back to plaintext.
        let tls_mode = DgraphTlsMode::try_from(dgraph.tls_mode.unwrap_or_default())
            .map_err(|err| FixtureError::configuration(format!("dgraph.tls_mode: {err}")))?;

        Ok(Self {
            host,
            port,
            tls_mode,
        })
    }

    /// Where this environment publishes the CA that verifies Dgraph, if it publishes one.
    ///
    /// Read here because this crate already loads the instance; the bundle itself is never
    /// fetched, because the health check runs with verification disabled and certificate
    /// material belongs to whoever opens a session.
    pub fn ca_bundle_url_from_config(identity: &Identity) -> Result<Option<String>, FixtureError> {
        let manager = ConfigManager::load(identity, built_ins(), &Filesystem).map_err(|err| {
            FixtureError::configuration(format!(
                "loading the '{}' instance failed: {err}",
                identity.kind()
            ))
        })?;
        Ok(manager.dgraph_ca_bundle_url().map(str::to_string))
    }

    /// Only for tests of this crate's own logic. Not a way around [`Self::from_config`].
    pub(crate) fn new(host: impl Into<String>, port: u16, tls_mode: DgraphTlsMode) -> Self {
        Self {
            host: host.into(),
            port,
            tls_mode,
        }
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn tls_mode(&self) -> DgraphTlsMode {
        self.tls_mode
    }

    /// True when Dgraph is terminating TLS.
    ///
    /// This decides the health check's scheme as well as the client's: enabling TLS moves the
    /// WHOLE of Dgraph's HTTP port to HTTPS, not just gRPC. A plain HTTP request to a TLS-enabled
    /// alpha is answered with `client sent an HTTP request to an HTTPS server` and nothing else.
    pub fn is_tls(&self) -> bool {
        !matches!(
            self.tls_mode,
            DgraphTlsMode::Unspecified | DgraphTlsMode::Disable
        )
    }

    fn scheme(&self) -> &'static str {
        if self.is_tls() { "https" } else { "http" }
    }

    /// THE READINESS URL. Answers only for the alpha that serves it, and answers 503 until that
    /// alpha can actually serve.
    ///
    /// Deliberately NOT `?all`. That variant reports cluster MEMBERSHIP, which goes green
    /// earlier: an alpha will list itself and its zero as healthy while still refusing gRPC with
    /// "Please retry again, server is not ready to accept requests". Gating on it produced
    /// exactly that -- a fixture that reported ready and a client that could not connect. The
    /// two endpoints answer two different questions and only this one is about readiness.
    pub fn health_url(&self) -> String {
        format!("{}://{}:{HTTP_PORT}/health", self.scheme(), self.host)
    }

    /// THE CLUSTER-WIDE URL, for asserting the shape of a deployment: one entry per server, so a
    /// CI check can require that every alpha and zero is up and grouped as configured rather than
    /// only that whichever one answered is alive.
    pub fn cluster_health_url(&self) -> String {
        format!("{}://{}:{HTTP_PORT}/health?all", self.scheme(), self.host)
    }

    /// The connection string a client parses, carrying the configured posture.
    ///
    /// The port is a parameter because `docker_utils` is authoritative about where a container
    /// actually landed; on the cluster path it is simply [`Self::port`].
    pub fn connection_string_at(&self, port: u16) -> String {
        let host = &self.host;
        match self.tls_mode {
            // Omitted rather than spelled out: plaintext is the client's default, so this is the
            // string a caller would actually write.
            DgraphTlsMode::Unspecified | DgraphTlsMode::Disable => format!("dgraph://{host}:{port}"),
            DgraphTlsMode::RequireNoVerify => format!("dgraph://{host}:{port}?sslmode=require"),
            DgraphTlsMode::VerifyCa => format!("dgraph://{host}:{port}?sslmode=verify-ca"),
        }
    }
}
