//! Where this crate's database coordinates come from.
//!
//! One variable, `SERVICERADAR_ENV`, and everything else follows from the identity it names --
//! host, port, roles, TLS posture from ConfigManager, and the password from the provider that
//! same identity selects. Nothing here reads a per-setting environment variable.
//!
//! What this replaced is worth stating, because the shape of the old code was a consequence of
//! the DSN being a string:
//!
//!   * `SRQL_TEST_DATABASE_URL` carried host, port, database, user, password and `sslmode` in
//!     one opaque value, so every property had to be recovered by PARSING it back out --
//!     `owner_from_url` for the role, `repoint_database` for the per-run name, and
//!     `require_verified_tls` to check a substring of the query string.
//!   * `sslmode=verify-full` is not a value tokio-postgres accepts, so `normalize_sslmode_for_
//!     tokio_postgres` rewrote the query string before parsing, and the verification it named
//!     had to be re-established separately from the connector.
//!
//! Assembling the DSN from typed fields removes all four: the role is a field, the per-run name
//! is substituted rather than rewritten, and the TLS posture is an enum that configures the
//! connector directly instead of a string that has to survive a round trip.

use anyhow::{Context, Result};
use serviceradar_config_manager::{ConfigManager, Dsn, Filesystem, Identity};
use serviceradar_config_schema::{RuleSet, TlsMode};
use serviceradar_secret_manager::{FileProvider, Manifest, SecretManager};

/// The logical name of the fixture password, identical in every environment.
pub const DATABASE_PASSWORD: &str = "database.password";

/// The CA the fixture certificate chains to. A logical name like any other.
pub const DATABASE_CA_CERT: &str = "database.ca_cert";

/// Locates a compiled artifact staged by Bazel.
///
/// There is deliberately no environment override. Both the rule set and the instance are
/// declared inputs, so a run cannot read a file the build graph does not know about.
pub(crate) fn runfile(relative: &str) -> Result<std::path::PathBuf> {
    let srcdir = std::env::var("TEST_SRCDIR")
        .or_else(|_| std::env::var("RUNFILES_DIR"))
        .context("TEST_SRCDIR is unset: this crate's inputs are staged by Bazel")?;

    let root = std::path::PathBuf::from(srcdir);
    ["_main", "serviceradar"]
        .iter()
        .map(|w| root.join(w).join(relative))
        .find(|c| c.exists())
        .with_context(|| format!("{relative} is not in runfiles; add it to the target's data"))
}

/// Everything the fixture needs, resolved once.
pub struct Fixture {
    manager: ConfigManager,
    password: String,
}

/// The committed rule set, as a declared build input.
///
/// Validation happens at LOAD (Decision 12), so the fixture needs the same rules the build
/// validated the instance against. Bazel stages it in runfiles; there is deliberately no
/// environment override that could repoint it.
fn load_rules() -> Result<RuleSet> {
    use prost::Message;

    let path = runfile("config/rules/ruleset.binpb")?;
    let bytes = std::fs::read(&path).with_context(|| format!("read {path:?}"))?;
    RuleSet::decode(&*bytes).with_context(|| format!("decode {path:?}"))
}

impl Fixture {
    /// Resolves everything from `SERVICERADAR_ENV`, loading the rule set from runfiles.
    pub fn from_env() -> Result<Self> {
        Self::resolve(&load_rules()?)
    }

    /// Resolves configuration and the fixture password from `SERVICERADAR_ENV`.
    pub fn resolve(rules: &RuleSet) -> Result<Self> {
        let identity = Identity::from_env().map_err(|e| anyhow::anyhow!("{e}"))?;

        // For a test binary, "compiled into the release" means "a declared input in my
        // runfiles". That is strictly better than an embedded blob here: the instance under
        // test is the artifact the build just produced and validated, and Bazel reruns the
        // test when it changes.
        let instance = runfile(&format!("config/environments/{}.binpb", identity.kind()))?;
        let bytes = std::fs::read(&instance).with_context(|| format!("read {instance:?}"))?;
        let built_ins: &[(&str, &[u8])] = &[(identity.kind(), &bytes)];

        let manager = ConfigManager::load(&identity, built_ins, rules, &Filesystem)
            .map_err(|e| anyhow::anyhow!("{e}"))?;

        let secrets = SecretManager::new(
            FileProvider::for_kind(identity.kind()),
            Manifest::new([DATABASE_PASSWORD]),
        );
        let password = secrets
            .resolve(DATABASE_PASSWORD)
            .map_err(|e| anyhow::anyhow!("{e}"))?;

        Ok(Self { manager, password: password.expose().to_string() })
    }

    /// The DSN for a specific database on the fixture server.
    pub fn database_url(&self, database: &str) -> Result<Dsn> {
        self.manager
            .database_url_named(database, &self.password)
            .context("the loaded configuration has no usable database section")
    }

    /// The role that owns per-run databases. A field, not something recovered from a DSN.
    pub fn owning_role(&self) -> Result<&str> {
        self.manager
            .database()
            .and_then(|d| d.owning_role.as_deref())
            .context("database.owning_role is not set")
    }

    /// The database the admin connection targets when none is named.
    pub fn admin_database(&self) -> Result<&str> {
        self.manager
            .database()
            .and_then(|d| d.database.as_deref())
            .context("database.database is not set")
    }

    /// The TLS posture, typed.
    ///
    /// Returned as an enum rather than baked into the DSN because `verify-ca` and `verify-full`
    /// are not values tokio-postgres parses: the connector has to be built to match, and a
    /// string in the query would have to be translated back into exactly this decision.
    pub fn tls_mode(&self) -> Result<TlsMode> {
        let raw = self
            .manager
            .database()
            .and_then(|d| d.tls_mode)
            .context("database.tls_mode is not set")?;
        TlsMode::try_from(raw).map_err(|_| anyhow::anyhow!("database.tls_mode is out of range"))
    }

    /// The name TLS verification is performed against, when the mode demands one.
    pub fn tls_server_name(&self) -> Option<&str> {
        self.manager.database().and_then(|d| d.tls_server_name.as_deref())
    }

    pub fn identity(&self) -> &Identity {
        self.manager.identity()
    }

    /// The CA the fixture certificate chains to.
    ///
    /// Certificate material is SecretManager's, not the schema's -- config.proto deliberately
    /// carries the TLS MODE and the SERVER NAME but no `*_cert_file`, because a path to a
    /// credential is still a credential's location. It is declared, so a component that does not
    /// list it cannot read it.
    ///
    /// Absent is legal: it is only required when the mode verifies.
    pub fn ca_pem(&self) -> Result<Option<Vec<u8>>> {
        let identity = self.manager.identity();
        let secrets = SecretManager::new(
            FileProvider::for_kind(identity.kind()),
            Manifest::new([DATABASE_CA_CERT]),
        );

        match secrets.resolve(DATABASE_CA_CERT) {
            Ok(pem) => Ok(Some(pem.expose().as_bytes().to_vec())),
            Err(e) => match self.tls_mode()? {
                TlsMode::Disable | TlsMode::Require => Ok(None),
                _ => Err(anyhow::anyhow!(
                    "database.tls_mode verifies the server, so {DATABASE_CA_CERT} is required: {e}"
                )),
            },
        }
    }
}
