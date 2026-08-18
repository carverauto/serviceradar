//! Where secrets come from.

use crate::errors::SecretError;
use crate::types::Secret;

/// Resolves a logical name to a value.
///
/// Logical names are identical across environments and languages; only the provider changes, and
/// which provider is in use follows from `SERVICERADAR_ENV` (spec: "a provider selected by
/// SERVICERADAR_ENV"). A component therefore asks for `database.password` everywhere.
pub trait SecretProvider {
    /// A short name for diagnostics. An unresolvable secret must say WHICH store was consulted,
    /// or the reader cannot tell where to put the missing value.
    fn describe(&self) -> &str;

    fn resolve(&self, name: &str) -> Result<Secret, SecretError>;
}

/// Where a deployment mounts its secrets.
///
/// A constant for the same reason the instance mount is one: the platform decides what to put
/// there, and a settable path would be a second thing able to disagree with the environment.
/// Kubernetes secrets, Docker secrets and a developer's directory are all files, so one provider
/// serves every environment.
pub const MOUNTED_SECRETS_DIR: &str = "/etc/serviceradar/secrets";

/// Where a developer machine keeps its fixture credentials, relative to the home directory.
///
/// Home-relative rather than repository-relative because a sandboxed test action has neither the
/// repository nor its working directory: a relative path resolves against whatever the runner
/// chose, which is the ambient-input class this system removes. Never a deployed path.
pub const LOCAL_SECRETS_SUBDIR: &str = ".serviceradar/secrets";

/// One file per logical name, which is how Kubernetes and Docker present secrets.
#[derive(Debug, Clone)]
pub struct FileProvider {
    dir: String,
    label: String,
}

impl FileProvider {
    pub fn new(dir: impl Into<String>, label: impl Into<String>) -> Self {
        Self { dir: dir.into(), label: label.into() }
    }

    pub fn mounted() -> Self {
        Self::new(MOUNTED_SECRETS_DIR, format!("file({MOUNTED_SECRETS_DIR})"))
    }

    /// The provider the environment selects.
    ///
    /// A component never names a provider: the same `SERVICERADAR_ENV` that chooses the
    /// configuration chooses where credentials come from. `localhost` reads a repository-local
    /// directory because a developer machine has no platform mounting anything into /etc, and
    /// requiring one would make the first run fail on a path rather than on anything they did.
    pub fn for_kind(kind: &str) -> Self {
        match kind {
            "localhost" => {
                // HOME is a PLATFORM variable, not ServiceRadar configuration, so reading it
                // adds no setting anyone can point somewhere else -- there is deliberately no
                // ServiceRadar variable for the store location, because a settable path is a
                // second thing able to disagree with the environment.
                //
                // One caveat belongs here rather than in a caller: Bazel REWRITES HOME to a
                // per-test scratch directory, so under a test action this resolves inside the
                // sandbox and finds nothing. The fix is to restore the platform value with
                // `--test_env=HOME` in the profile that runs these tests, NOT to introduce a
                // path setting.
                match std::env::var("HOME") {
                    Ok(home) if !home.is_empty() => {
                        let dir = format!("{home}/{LOCAL_SECRETS_SUBDIR}");
                        Self::new(dir.clone(), format!("file({dir})"))
                    }
                    // Failing loudly naming a path beats silently reading nothing.
                    _ => Self::mounted(),
                }
            }
            _ => Self::mounted(),
        }
    }
}

impl SecretProvider for FileProvider {
    fn describe(&self) -> &str {
        &self.label
    }

    fn resolve(&self, name: &str) -> Result<Secret, SecretError> {
        let path = std::path::Path::new(&self.dir).join(name);
        match std::fs::read_to_string(&path) {
            // A trailing newline is an artefact of how the file was written, not part of the
            // secret. Everything else is preserved: a password may legitimately contain spaces.
            Ok(raw) => Secret::new(raw.trim_end_matches(['\n', '\r'])).ok_or_else(|| {
                SecretError::Unresolvable {
                    name: name.to_string(),
                    provider: self.label.clone(),
                }
            }),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Err(SecretError::Unresolvable {
                    name: name.to_string(),
                    provider: self.label.clone(),
                })
            }
            Err(e) => Err(SecretError::Provider {
                name: name.to_string(),
                provider: self.label.clone(),
                detail: e.to_string(),
            }),
        }
    }
}
