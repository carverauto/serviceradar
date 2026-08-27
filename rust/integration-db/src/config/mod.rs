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
use runfiles::Runfiles;
use serviceradar_config_manager::{
    ConfigManager, Dsn, Filesystem, Identity, DATABASE_ADMIN_PASSWORD, DATABASE_CA_CERT,
    DATABASE_PASSWORD,
};
use serviceradar_config_schema::TlsMode;
use serviceradar_secret_manager::{EnvironmentProvider, Manifest, SecretManager};

/// This module's own repository, as MODULE.bazel declares it.
///
/// The first segment of an rlocation path is an APPARENT repository name, which the runfiles
/// repo mapping resolves to the canonical directory (`_main`). Naming it here rather than
/// guessing the canonical form is the difference between reading a declaration and reading a
/// coincidence.
const THIS_REPO: &str = "serviceradar";

/// The main repository's canonical name is empty in the repo mapping, which is what the
/// `rlocation!` macro passes as `REPOSITORY_NAME`. That macro is not usable here: it resolves
/// the name at COMPILE time from an environment variable only rules_rust sets, so a crate that
/// must also build under plain `cargo` cannot call it.
const THIS_REPO_CANONICAL: &str = "";

/// Locates a declared build input staged by Bazel.
///
/// Uses the Bazel ecosystem's reference implementation (`@rules_rust//rust/runfiles`, published
/// as the `runfiles` crate) rather than a hand-rolled lookup. That is not tidiness -- the
/// hand-rolled version was measurably wrong twice:
///
///   * It read `TEST_SRCDIR`/`RUNFILES_DIR` only. Under `bazel run` -- which is how
///     `prepare_template` executes -- neither is set, and the runfiles directory has to be
///     derived from `argv[0]` as `<binary>.runfiles`. `prepare_template` failed on exactly this.
///   * It located files with `Path::exists`, which cannot work in MANIFEST mode, where runfiles
///     is a text manifest rather than a symlink tree.
///
/// It also guessed the repository directory by trying `_main` then `serviceradar`, where the
/// library consults the repo mapping the build actually emitted.
///
/// There is deliberately no environment override: every input here is declared, so a run must
/// not be able to read a file the build graph does not know about.
pub(crate) fn runfile(relative: &str) -> Result<std::path::PathBuf> {
    let runfiles = Runfiles::create()
        .map_err(|e| anyhow::anyhow!("{e:?}"))
        .context("this crate's inputs are staged by Bazel; runfiles could not be located")?;

    let path = runfiles
        .rlocation_from(format!("{THIS_REPO}/{relative}"), THIS_REPO_CANONICAL)
        .with_context(|| format!("{relative} is not in runfiles; add it to the target's data"))?;

    if !path.exists() {
        anyhow::bail!(
            "{relative} resolved to {}, which does not exist",
            path.display()
        );
    }

    Ok(path)
}

/// Everything the fixture needs, resolved once.
pub struct Fixture {
    manager: ConfigManager,
    password: String,
    admin_password: String,
}

impl Fixture {
    /// Resolves everything from `SERVICERADAR_ENV`, loading the rule set from runfiles.
    pub fn from_env() -> Result<Self> {
        Self::resolve()
    }

    /// Resolves configuration and the fixture password from `SERVICERADAR_ENV`.
    pub fn resolve() -> Result<Self> {
        let identity = Identity::from_env().map_err(|e| anyhow::anyhow!("{e}"))?;

        // For a test binary, "compiled into the release" means "a declared input in my
        // runfiles". That is strictly better than an embedded blob here: the instance under
        // test is the artifact the build just produced and validated, and Bazel reruns the
        // test when it changes.
        let instance = runfile(&format!("config/environments/{}.binpb", identity.kind()))?;
        let bytes = std::fs::read(&instance).with_context(|| format!("read {instance:?}"))?;
        let built_ins: &[(&str, &[u8])] = &[(identity.kind(), &bytes)];

        let manager = ConfigManager::load(&identity, built_ins, &Filesystem)
            .map_err(|e| anyhow::anyhow!("{e}"))?;

        // Both roles, resolved together: a lifecycle that discovers the admin credential only
        // when it first provisions fails halfway through a run rather than at its start.
        let secrets = SecretManager::new(
            EnvironmentProvider::for_kind(identity.kind()),
            Manifest::new([DATABASE_PASSWORD, DATABASE_ADMIN_PASSWORD]),
        );
        let password = secrets
            .resolve(DATABASE_PASSWORD)
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        let admin_password = secrets
            .resolve(DATABASE_ADMIN_PASSWORD)
            .map_err(|e| anyhow::anyhow!("{e}"))?;

        Ok(Self {
            manager,
            password: password.expose().to_string(),
            admin_password: admin_password.expose().to_string(),
        })
    }

    /// The DSN for a specific database on the fixture server.
    pub fn database_url(&self, database: &str) -> Result<Dsn> {
        self.manager
            .database_url_named(database, &self.password)
            .context("the loaded configuration has no usable database section")
    }

    /// The DSN for the role that may CREATE and DROP databases.
    ///
    /// A separate identity AND a separate password from [`Self::database_url`]: the suite
    /// connects as the application role, which deliberately lacks CREATEDB.
    pub fn admin_url_for(&self, database: &str) -> Result<Dsn> {
        let role = self
            .manager
            .admin_role()
            .context("database.admin_role is not set, so no role may create the run database")?;
        self.manager
            .database_url_as(role, database, &self.admin_password)
            .context("the loaded configuration has no usable database section")
    }

    /// The role that owns per-run databases. A field, not something recovered from a DSN.
    /// The database the environment declares, as a field rather than a path parsed back out of
    /// a DSN.
    pub fn database_name(&self) -> Result<&str> {
        self.manager
            .database()
            .and_then(|d| d.database.as_deref())
            .context("the environment declares no database.database")
    }

    pub fn owning_role(&self) -> Result<&str> {
        self.manager
            .database()
            .and_then(|d| d.owning_role.as_deref())
            .context("database.owning_role is not set")
    }

    /// The database the admin connection targets when none is named.
    /// The maintenance database an admin connection opens, so CREATE/DROP DATABASE never runs
    /// from inside the database being created or dropped -- and is not killed when something
    /// terminates the fixture's backends.
    pub fn admin_database(&self) -> Result<&str> {
        Ok("postgres")
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

    /// The published CA bundle the fixture certificate chains to, when one is configured.
    ///
    /// Exposed for diagnostics as well as for [`Self::ca_pem`]: a connection failure has to be
    /// able to say whether trust came from a URL, and which one.
    pub fn ca_bundle_url(&self) -> Option<&str> {
        self.manager.ca_bundle_url()
    }

    /// The name TLS verification is performed against, when the mode demands one.
    pub fn tls_server_name(&self) -> Option<&str> {
        self.manager
            .database()
            .and_then(|d| d.tls_server_name.as_deref())
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
        // A named bundle wins, and nothing carries the PEM. A cert-manager issuer rotates, so
        // any copy -- a CI secret, an instance file, a mounted blob -- is correct until it is
        // not, and the failure lands on whoever runs the suite that day rather than on whoever
        // stored it. Reading the published bundle each run makes a stale CA impossible rather
        // than merely unlikely.
        if let Some(url) = self.manager.ca_bundle_url() {
            let pem = serviceradar_config_manager::fetch_ca_bundle(url)?;
            return Ok(Some(pem));
        }

        let identity = self.manager.identity();
        let secrets = SecretManager::new(
            EnvironmentProvider::for_kind(identity.kind()),
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
