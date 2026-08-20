//! Secrets presented as environment variables.

use crate::errors::SecretError;
use crate::traits::SecretProvider;
use crate::types::Secret;

/// The prefix every secret variable carries.
///
/// A prefix rather than a per-secret name, so the set of variables a component reads is
/// DERIVED from its manifest instead of listed somewhere that can disagree with it. The
/// hand-maintained list this replaces forwarded 43 names, 38 of which nothing ever set.
pub const SECRET_ENV_PREFIX: &str = "SERVICERADAR_SECRET_";

/// Secrets read from the process environment.
///
/// This is the provider the platform actually uses. `//helm/serviceradar` supplies every
/// credential with `valueFrom.secretKeyRef`, which is a Kubernetes Secret projected as an
/// ENVIRONMENT VARIABLE -- 38 of them across the chart -- and nothing anywhere mounts
/// [`crate::MOUNTED_SECRETS_DIR`]. BuildBuddy has no other channel at all: a workflow secret
/// arrives as a variable, and a Bazel test action receives it only through `--test_env`.
///
/// [`crate::FileProvider`] remains for the other Kubernetes shape, a projected Secret volume,
/// and for Docker secrets. Neither is deployed here today.
#[derive(Debug, Clone)]
pub struct EnvProvider {
    label: String,
}

impl Default for EnvProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl EnvProvider {
    pub fn new() -> Self {
        Self { label: format!("env({SECRET_ENV_PREFIX}*)") }
    }

    /// The variable a logical name is read from: `database.password` ->
    /// `SERVICERADAR_SECRET_DATABASE_PASSWORD`.
    ///
    /// Total and mechanical, because the alternative is a mapping table -- a second place able
    /// to disagree with the manifest, which is the failure this whole system exists to remove.
    /// A caller that knows the logical name can compute the variable, so the workflow's
    /// `--test_env` list is generated rather than written.
    pub fn variable_for(name: &str) -> String {
        let mut out = String::with_capacity(SECRET_ENV_PREFIX.len() + name.len());
        out.push_str(SECRET_ENV_PREFIX);
        for c in name.chars() {
            out.push(match c {
                '.' | '-' | '/' => '_',
                other => other.to_ascii_uppercase(),
            });
        }
        out
    }
}

impl SecretProvider for EnvProvider {
    fn describe(&self) -> &str {
        &self.label
    }

    fn resolve(&self, name: &str) -> Result<Secret, SecretError> {
        let variable = Self::variable_for(name);
        // An empty variable is treated as absent, not as an empty credential. A set-but-blank
        // secret is how a misconfigured deployment authenticates as nobody and gets a confusing
        // error from the server instead of a clear one from here.
        match std::env::var(&variable) {
            Ok(value) => Secret::new(value.trim_end_matches(['\n', '\r'])).ok_or_else(|| {
                SecretError::Unresolvable { name: name.to_string(), provider: self.label.clone() }
            }),
            Err(_) => Err(SecretError::Unresolvable {
                name: name.to_string(),
                provider: self.label.clone(),
            }),
        }
    }
}
