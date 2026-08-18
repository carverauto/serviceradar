//! Which environment this process is, read from the one variable that decides it.
//!
//! `SERVICERADAR_ENV` is the ONLY input. It is required and has no default: a component that
//! guessed an environment would guess a database, and the wrong guess is silent. Everything
//! else -- which instance to load, where it comes from, which secret provider resolves
//! credentials -- is derived from the identity this yields.

use std::fmt;

pub const ENV_VAR: &str = "SERVICERADAR_ENV";

/// The kinds that do not accept an instance identifier. `onprem` requires one.
const SINGLE_INSTANCE_KINDS: &[&str] = &["localhost", "ci", "saas", "demo"];
const ONPREM: &str = "onprem";

/// The environment identity, as `<kind>[":" <instance>]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    pub kind: String,
    pub instance: Option<String>,
}

impl fmt::Display for Identity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.instance {
            Some(i) => write!(f, "{}:{}", self.kind, i),
            None => write!(f, "{}", self.kind),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SelectorError {
    Absent,
    UnknownKind(String),
    InstanceRequired(String),
    InstanceNotAccepted(String),
}

impl fmt::Display for SelectorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            // The one failure a reader may be meeting for the first time, possibly at 3am, in a
            // crash loop with no other output. It says what is wrong, why nothing can proceed,
            // exactly what to set, and how to set it on each platform -- because the reader's
            // next action is editing a manifest, not reading source.
            Self::Absent => write!(
                f,
                "\n\
                 ==============================================================================\n\
                 SERVICERADAR CANNOT START: {ENV_VAR} is not set.\n\
                 ==============================================================================\n\
                 \n\
                 This one environment variable declares WHICH ServiceRadar environment this\n\
                 process is running in. Everything else is derived from it: the database, the\n\
                 message bus, the TLS posture, and which provider resolves secrets. Nothing can\n\
                 be loaded until it is set.\n\
                 \n\
                 There is deliberately NO DEFAULT. A guessed environment is a guessed database,\n\
                 and guessing wrong is silent -- the process would start and connect somewhere\n\
                 nobody chose.\n\
                 \n\
                 Set {ENV_VAR} to exactly one of:\n\
                 \n\
                   {}\n\
                   {ONPREM}:<instance>     (on-prem is multi-instance; name the deployment)\n\
                 \n\
                 How to set it:\n\
                 \n\
                   Kubernetes   env:\n\
                                  - name: {ENV_VAR}\n\
                                    value: saas\n\
                   Docker       docker run -e {ENV_VAR}=saas ...\n\
                   Compose      environment:\n\
                                  {ENV_VAR}: saas\n\
                   CI           export {ENV_VAR}=ci\n\
                   Local dev    export {ENV_VAR}=localhost\n\
                 ==============================================================================",
                SINGLE_INSTANCE_KINDS.join("\n                   ")
            ),
            Self::UnknownKind(k) => write!(
                f,
                "{ENV_VAR}={k:?} names no environment kind. Valid: {}, {ONPREM}:<instance>.",
                SINGLE_INSTANCE_KINDS.join(", ")
            ),
            Self::InstanceRequired(k) => {
                write!(f, "{ENV_VAR}={k:?} requires an instance identifier, as {k}:<instance>.")
            }
            Self::InstanceNotAccepted(k) => {
                write!(f, "{ENV_VAR} kind {k:?} does not accept an instance identifier.")
            }
        }
    }
}

impl std::error::Error for SelectorError {}

/// Parses the identity from the variable's value.
///
/// Takes the value rather than reading the environment so this stays a total function of its
/// input and is testable without mutating process state.
pub fn resolve(value: Option<&str>) -> Result<Identity, SelectorError> {
    // Empty is unset, not a choice: a shell exporting `SERVICERADAR_ENV=` has selected nothing,
    // and this repository's build tooling pins several variables to "" deliberately.
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
                Ok(Identity { kind: kind.to_string(), instance: Some(i) })
            }
            _ => Err(SelectorError::InstanceRequired(kind.to_string())),
        };
    }
    if !SINGLE_INSTANCE_KINDS.contains(&kind) {
        return Err(SelectorError::UnknownKind(value.to_string()));
    }
    if instance.is_some() {
        return Err(SelectorError::InstanceNotAccepted(kind.to_string()));
    }
    Ok(Identity { kind: kind.to_string(), instance: None })
}

/// Reads the one variable from the process environment.
pub fn from_env() -> Result<Identity, SelectorError> {
    resolve(std::env::var(ENV_VAR).ok().as_deref())
}
