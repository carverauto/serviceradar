//! The environment identity, parsed from the one variable that decides it.

use crate::errors::SelectorError;

/// The only environment variable a component reads to determine its configuration.
pub const ENV_VAR: &str = "SERVICERADAR_ENV";

/// Kinds that do not accept an instance identifier. `onprem` requires one.
pub(crate) const SINGLE_INSTANCE_KINDS: &[&str] = &["localhost", "ci", "saas", "demo"];
pub(crate) const ONPREM: &str = "onprem";

/// An environment, as `<kind>[":" <instance>]`.
///
/// Fields are private: an `Identity` that did not come from [`Identity::parse`] could name a kind
/// the system does not have, and every later decision keys on the kind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    kind: String,
    instance: Option<String>,
}

impl Identity {
    /// Parses the identity from the variable's value.
    ///
    /// Takes the value rather than reading the environment, so this stays a total function of
    /// its input and is testable without mutating process state.
    pub fn parse(value: Option<&str>) -> Result<Self, SelectorError> {
        // Empty is unset, not a choice: a shell exporting `SERVICERADAR_ENV=` has selected
        // nothing, and this repository's build tooling pins several variables to "".
        let value = value.map(str::trim).filter(|s| !s.is_empty());
        let Some(value) = value else {
            return Err(SelectorError::Absent);
        };

        let (kind, instance) = match value.split_once(':') {
            Some((k, i)) => (k, Some(i.to_string())),
            None => (value, None),
        };

        if kind == ONPREM {
            return match instance {
                Some(i) if !i.is_empty() => {
                    Ok(Self { kind: kind.to_string(), instance: Some(i) })
                }
                _ => Err(SelectorError::InstanceRequired(ONPREM.to_string())),
            };
        }
        if !SINGLE_INSTANCE_KINDS.contains(&kind) {
            return Err(SelectorError::UnknownKind(value.to_string()));
        }
        if instance.is_some() {
            return Err(SelectorError::InstanceNotAccepted(kind.to_string()));
        }
        Ok(Self { kind: kind.to_string(), instance: None })
    }

    /// Reads the one variable from the process environment.
    pub fn from_env() -> Result<Self, SelectorError> {
        Self::parse(std::env::var(ENV_VAR).ok().as_deref())
    }

    /// Builds an identity from parts already known to be valid, such as the `kind` and
    /// `instance` of a decoded artifact.
    pub(crate) fn from_parts(kind: String, instance: Option<String>) -> Self {
        Self { kind, instance }
    }

    pub fn kind(&self) -> &str {
        &self.kind
    }

    pub fn instance(&self) -> Option<&str> {
        self.instance.as_deref()
    }
}

mod identity_display;
