//! A Dgraph the caller may connect to.

use crate::errors::fixture_error::FixtureError;
use crate::traits::instance_provider::InstanceProvider;
use crate::types::container_provider::ContainerProvider;
use crate::types::endpoint::Endpoint;
use crate::types::exclusivity::Exclusivity;
use crate::types::existing_provider::ExistingProvider;
use crate::types::run_id::RunId;
use crate::types::strategy::Strategy;
use serviceradar_config_manager::{ENV_VAR, Identity};

/// A running Dgraph, and everything a caller needs to know about it.
///
/// Every field private: an instance that did not come from [`Self::acquire`] could claim an
/// exclusivity it does not have, and exclusivity is what callers use to decide whether they may
/// destroy data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DgraphInstance {
    endpoint: Endpoint,
    strategy: Strategy,
    port: u16,
    connection_string: String,
    container_id: Option<String>,
    identity_kind: String,
    run_id: RunId,
    ca_bundle_url: Option<String>,
}

impl DgraphInstance {
    /// Resolve `SERVICERADAR_ENV`, obtain a Dgraph however that environment requires, and return
    /// only once it reports healthy.
    ///
    /// Blocking, not async, on purpose: `docker_utils` is synchronous and so is the health check,
    /// so there is nothing to await. That also makes this callable from a plain `#[test]` and from
    /// `#[tokio::test]` alike, with no ambient runtime required either way.
    pub fn acquire() -> Result<Self, FixtureError> {
        let identity = Identity::from_env().map_err(|err| {
            FixtureError::configuration(format!("{ENV_VAR} does not name a usable environment: {err}"))
        })?;
        Self::acquire_as(&identity)
    }

    /// [`Self::acquire`] for an identity already in hand.
    pub fn acquire_as(identity: &Identity) -> Result<Self, FixtureError> {
        let strategy = Strategy::for_identity(identity)?;
        let endpoint = Endpoint::from_config(identity)?;
        let ca_bundle_url = Endpoint::ca_bundle_url_from_config(identity)?;

        // Static dispatch: each arm monomorphises, nothing is boxed.
        let (port, container_id) = match strategy {
            Strategy::Container => ContainerProvider.acquire(&endpoint)?,
            Strategy::Existing => ExistingProvider.acquire(&endpoint)?,
        };

        Ok(Self {
            connection_string: endpoint.connection_string_at(port),
            endpoint,
            strategy,
            port,
            container_id,
            identity_kind: identity.kind().to_string(),
            run_id: RunId::resolve(),
            ca_bundle_url,
        })
    }

    /// `dgraph://host:port[?sslmode=...]`, ready to hand to a client.
    pub fn connection_string(&self) -> &str {
        &self.connection_string
    }

    pub fn host(&self) -> &str {
        self.endpoint.host()
    }

    /// Where the instance actually is, which on the container path is what `docker_utils`
    /// reported rather than what was configured.
    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }

    pub fn strategy(&self) -> Strategy {
        self.strategy
    }

    pub fn identity_kind(&self) -> &str {
        &self.identity_kind
    }

    /// Whether this process owns the instance.
    ///
    /// Callers that wipe data MUST branch on this. A container this run started is
    /// [`Exclusivity::Exclusive`]; the CI cluster is shared with every concurrent pull request
    /// and is [`Exclusivity::Shared`].
    pub fn exclusivity(&self) -> Exclusivity {
        self.strategy.exclusivity()
    }

    /// This run's correlation id.
    ///
    /// The reason a caller wants it is data scoping. Dgraph namespaces do NOT isolate without
    /// ACL -- verified against the CI cluster: a write inside namespace N is visible from
    /// namespace 0 -- so a suite sharing the fixture must keep out of other runs' way by naming
    /// its own data, exactly as `//rust/integration-db` names its own database.
    pub fn run_id(&self) -> &RunId {
        &self.run_id
    }

    /// Where the CA that verifies this cluster is published, when the instance names one.
    ///
    /// The URL only. This crate never reads certificate material: its own health check runs
    /// with verification disabled because liveness is not an identity question, and fetching a
    /// bundle it does not use would be borrowing a responsibility that belongs to the client.
    pub fn ca_bundle_url(&self) -> Option<&str> {
        self.ca_bundle_url.as_deref()
    }

    /// The connection string with extra parameters appended, for a caller that needs to add a
    /// CA path or select a namespace.
    pub fn connection_string_with(&self, params: &[(&str, &str)]) -> String {
        let mut out = self.connection_string.clone();
        for (key, value) in params {
            out.push(if out.contains('?') { '&' } else { '?' });
            out.push_str(key);
            out.push('=');
            out.push_str(value);
        }
        out
    }

    /// The connection string with ACL credentials and extra parameters.
    ///
    /// Pure string assembly -- this crate neither logs in nor holds a session. The caller owns
    /// the credential, resolves it through SecretManager, and decides which identity to use;
    /// all that happens here is percent-encoding it into the userinfo the client parses.
    pub fn connection_string_as(
        &self,
        username: &str,
        password: &str,
        params: &[(&str, &str)],
    ) -> String {
        // The password can contain anything a generator produced, and ':' or '@' inside it
        // would otherwise re-split the authority.
        let user = encode(username);
        let pass = encode(password);
        let rest = self
            .connection_string
            .strip_prefix("dgraph://")
            .unwrap_or(&self.connection_string);

        let mut out = format!("dgraph://{user}:{pass}@{rest}");
        for (key, value) in params {
            out.push(if out.contains('?') { '&' } else { '?' });
            out.push_str(key);
            out.push('=');
            out.push_str(value);
        }
        out
    }

    /// Container id, when one was created. `None` on the cluster path.
    pub fn container_id(&self) -> Option<&str> {
        self.container_id.as_deref()
    }

    /// One printable line naming what was obtained and how.
    pub fn describe(&self) -> String {
        format!(
            "{}:{} via {} ({:?}, {}={})",
            self.host(),
            self.port,
            self.strategy.as_str(),
            self.exclusivity(),
            ENV_VAR,
            self.identity_kind
        ) + &format!(
            ", run={}{}",
            self.run_id.as_str(),
            if self.run_id.is_supplied() { "" } else { " (local)" }
        )
    }
}

/// Percent-encode the characters that would otherwise re-split a `dgraph://` authority.
fn encode(value: &str) -> String {
    value
        .chars()
        .map(|c| match c {
            ':' => "%3A".to_string(),
            '@' => "%40".to_string(),
            '/' => "%2F".to_string(),
            '?' => "%3F".to_string(),
            '#' => "%23".to_string(),
            other => other.to_string(),
        })
        .collect()
}
