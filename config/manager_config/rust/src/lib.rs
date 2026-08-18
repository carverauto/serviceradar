//! Resolves a component's environment configuration from one variable, and validates it before
//! returning a value.
//!
//! `SERVICERADAR_ENV` is the only input. Everything else follows from the identity it names:
//! which instance to load, where that instance comes from, and -- for SecretManager -- which
//! provider resolves credentials. A component never learns a second variable.
//!
//! Loading validates. Decision 10's guarantee is that no instance is loaded that has not been
//! checked against the committed rule set; a committed instance is checked at BUILD time and
//! then trusted, so checking here is what makes the guarantee hold for an instance the build
//! never saw.

#![forbid(unsafe_code)]

pub mod selector;

use prost::Message;
use serviceradar_config_schema::{EnvironmentConfig, EnvironmentKind, RuleSet};
use serviceradar_config_validator::{validate, Violation};

pub use selector::{Identity, SelectorError, ENV_VAR};

/// Where a deployed environment's instance is mounted.
///
/// A constant, not a variable. The platform decides WHICH environment a container is by setting
/// `SERVICERADAR_ENV`, and mounts the matching artifact here; making the path settable too would
/// add a second thing that can disagree with the first, which is what the identity check below
/// exists to catch rather than to permit.
pub const MOUNTED_INSTANCE_PATH: &str = "/etc/serviceradar/environment.binpb";

/// Where the bytes for an identity come from.
///
/// `localhost` and `ci` carry theirs in the artifact because neither has a platform to mount
/// anything: a developer running `cargo run` and a Bazel test action both have a filesystem
/// nobody provisioned. Every deployed kind reads the mount.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    BuiltIn { name: String },
    Mounted { path: String },
}

impl Source {
    pub fn for_identity(identity: &Identity) -> Self {
        match identity.kind.as_str() {
            "localhost" | "ci" => Self::BuiltIn { name: identity.to_string() },
            _ => Self::Mounted { path: MOUNTED_INSTANCE_PATH.to_string() },
        }
    }
}

impl std::fmt::Display for Source {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BuiltIn { name } => write!(f, "built-in:{name}"),
            Self::Mounted { path } => write!(f, "{path}"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Loaded {
    pub config: EnvironmentConfig,
    pub identity: Identity,
    /// Carried from the first version even when it is trivially a built-in name: `explain` has
    /// to report where a value came from, and there is nowhere to put an endpoint or a fetch
    /// time if loading returns a bare message.
    pub source: Source,
}

#[derive(Debug)]
pub enum ConfigError {
    Selector(SelectorError),
    UnknownBuiltIn { name: String, available: Vec<String> },
    Read { source: Source, detail: String },
    Decode { source: Source, detail: String },
    /// The rule set names a field the schema lacks. Distinct from a violation: the rule set is
    /// itself wrong, so no instance can be judged against it.
    RuleSet { detail: String },
    Invalid { source: Source, violations: Vec<Violation> },
    /// The artifact does not describe the environment that was selected.
    IdentityMismatch { selected: String, found: String, source: Source },
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Selector(e) => write!(f, "{e}"),
            Self::UnknownBuiltIn { name, available } => write!(
                f,
                "no configuration named {name:?} is built into this release. Available: {}.",
                available.join(", ")
            ),
            Self::Read { source, detail } => {
                write!(f, "cannot read configuration from {source}: {detail}")
            }
            Self::Decode { source, detail } => {
                write!(f, "configuration from {source} is not an EnvironmentConfig: {detail}")
            }
            Self::RuleSet { detail } => {
                write!(f, "the rule set names a field the schema lacks: {detail}")
            }
            Self::Invalid { source, violations } => {
                writeln!(f, "configuration from {source} is invalid:")?;
                for v in violations {
                    writeln!(f, "  {:<34} {}", v.field_path, v.code)?;
                    if !v.description.is_empty() {
                        writeln!(f, "  {:<34}   {}", "", v.description)?;
                    }
                }
                Ok(())
            }
            Self::IdentityMismatch { selected, found, source } => write!(
                f,
                "{ENV_VAR}={selected} but {source} describes {found}. The wrong artifact is \
                 mounted: this component would connect to {found}'s database believing it is \
                 {selected}."
            ),
        }
    }
}

impl std::error::Error for ConfigError {}

/// The instances compiled into this release, as `(identity, encoded bytes)`.
pub type BuiltIns<'a> = &'a [(&'a str, &'a [u8])];

/// Reads the mounted artifact.
///
/// A trait so the manager never decides how a deployment reaches its own filesystem, and so the
/// mismatch and validation paths are testable without a mount.
pub trait ReadSource {
    fn read(&self, path: &str) -> Result<Vec<u8>, String>;
}

pub struct Filesystem;

impl ReadSource for Filesystem {
    fn read(&self, path: &str) -> Result<Vec<u8>, String> {
        std::fs::read(path).map_err(|e| e.to_string())
    }
}

fn kind_name(kind: Option<i32>) -> String {
    match kind.and_then(|k| EnvironmentKind::try_from(k).ok()) {
        Some(k) => k
            .as_str_name()
            .strip_prefix("ENVIRONMENT_KIND_")
            .unwrap_or("")
            .to_ascii_lowercase(),
        None => "<unset>".to_string(),
    }
}

/// Loads, validates, and confirms the artifact describes the environment that was selected.
///
/// There is deliberately no entry point that skips any of the three.
pub fn load(
    identity: &Identity,
    built_ins: BuiltIns<'_>,
    rules: &RuleSet,
    reader: &dyn ReadSource,
) -> Result<Loaded, ConfigError> {
    let source = Source::for_identity(identity);

    let bytes = match &source {
        Source::BuiltIn { name } => match built_ins.iter().find(|(n, _)| n == name) {
            Some((_, bytes)) => bytes.to_vec(),
            None => {
                return Err(ConfigError::UnknownBuiltIn {
                    name: name.clone(),
                    available: built_ins.iter().map(|(n, _)| (*n).to_string()).collect(),
                })
            }
        },
        // No cached fallback: a service that silently starts on last week's configuration is
        // worse than one that does not start.
        Source::Mounted { path } => match reader.read(path) {
            Ok(bytes) => bytes,
            Err(detail) => return Err(ConfigError::Read { source, detail }),
        },
    };

    let config = EnvironmentConfig::decode(&*bytes)
        .map_err(|e| ConfigError::Decode { source: source.clone(), detail: e.to_string() })?;

    // The artifact is self-describing and the selector is declared, so they can be compared.
    // This is what catches the wrong ConfigMap being mounted -- a mistake that is otherwise
    // completely silent and whose blast radius is the database a component connects to.
    let found = Identity { kind: kind_name(config.kind), instance: config.instance.clone() };
    if found != *identity {
        return Err(ConfigError::IdentityMismatch {
            selected: identity.to_string(),
            found: found.to_string(),
            source,
        });
    }

    let violations =
        validate(rules, &config).map_err(|e| ConfigError::RuleSet { detail: e.0 })?;
    if !violations.is_empty() {
        return Err(ConfigError::Invalid { source, violations });
    }

    Ok(Loaded { config, identity: identity.clone(), source })
}
