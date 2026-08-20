//! Why a Dgraph could not be obtained.

use crate::types::strategy::Strategy;
use std::fmt;

/// The error of every fallible operation in this crate.
///
/// The classification is wrapped rather than public so variants can be added without breaking
/// callers; branch on [`FixtureError::kind`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FixtureError(FixtureErrorEnum);

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum FixtureErrorEnum {
    /// `SERVICERADAR_ENV` names no usable environment, or its instance has no dgraph section.
    Configuration(String),
    /// A kind no test fixture may touch. `saas` and `demo` name production Dgraph.
    UnsupportedEnvironment { kind: String },
    /// `docker_utils` could not provide a container. Its error is a newtype over `String`
    /// upstream, so this is where the text survives; do not branch on its contents.
    Docker(String),
    /// The endpoint never became healthy inside its budget.
    NotReady {
        host: String,
        port: u16,
        attempts: u32,
        last: String,
    },
    /// `/health?all` answered, but not with something this crate can read.
    Health { url: String, detail: String },
}

impl FixtureError {
    pub fn new(kind: FixtureErrorEnum) -> Self {
        Self(kind)
    }

    pub fn kind(&self) -> &FixtureErrorEnum {
        &self.0
    }

    pub fn is_not_ready(&self) -> bool {
        matches!(self.0, FixtureErrorEnum::NotReady { .. })
    }

    pub fn is_unsupported_environment(&self) -> bool {
        matches!(self.0, FixtureErrorEnum::UnsupportedEnvironment { .. })
    }
}

impl fmt::Display for FixtureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.0 {
            FixtureErrorEnum::Configuration(detail) => {
                write!(f, "the dgraph endpoint could not be resolved: {detail}")
            }
            // Names the whole rule rather than just the refusal: the reader's next question is
            // always "then which ones DO work", and the answer is short enough to just say.
            FixtureErrorEnum::UnsupportedEnvironment { kind } => write!(
                f,
                "SERVICERADAR_ENV={kind:?} is not an environment a test fixture may touch. \
                 Only 'localhost' (provisions a container) and 'ci' (verifies the cluster \
                 fixture) are supported; 'saas' and 'demo' name production Dgraph."
            ),
            FixtureErrorEnum::Docker(detail) => write!(f, "docker could not provide Dgraph: {detail}"),
            FixtureErrorEnum::NotReady {
                host,
                port,
                attempts,
                last,
            } => write!(
                f,
                "{host}:{port} did not become healthy after {attempts} attempt(s); last: {last}"
            ),
            FixtureErrorEnum::Health { url, detail } => {
                write!(f, "{url} did not answer with a usable health report: {detail}")
            }
        }
    }
}

impl std::error::Error for FixtureError {}

impl FixtureError {
    pub(crate) fn configuration(detail: impl Into<String>) -> Self {
        Self(FixtureErrorEnum::Configuration(detail.into()))
    }

    pub(crate) fn unsupported(kind: impl Into<String>) -> Self {
        Self(FixtureErrorEnum::UnsupportedEnvironment { kind: kind.into() })
    }

    pub(crate) fn docker(detail: impl Into<String>) -> Self {
        Self(FixtureErrorEnum::Docker(detail.into()))
    }

    pub(crate) fn not_ready(host: &str, port: u16, attempts: u32, last: impl Into<String>) -> Self {
        Self(FixtureErrorEnum::NotReady {
            host: host.to_string(),
            port,
            attempts,
            last: last.into(),
        })
    }

    pub(crate) fn health(url: impl Into<String>, detail: impl Into<String>) -> Self {
        Self(FixtureErrorEnum::Health {
            url: url.into(),
            detail: detail.into(),
        })
    }
}

/// Strategy is carried in errors often enough to warrant the conversion being obvious.
impl From<Strategy> for &'static str {
    fn from(strategy: Strategy) -> Self {
        strategy.as_str()
    }
}
