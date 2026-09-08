//! Why a secret could not be resolved. Never a default, never an empty value.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretError {
    /// The component asked for a name it did not declare.
    Undeclared { name: String, declared: Vec<String> },
    /// The provider has no entry under that name.
    Unresolvable { name: String, provider: String },
    /// The provider itself failed -- unreadable mount, unreachable store.
    Provider { name: String, provider: String, detail: String },
}

impl fmt::Display for SecretError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Undeclared { name, declared } => write!(
                f,
                "secret {name:?} was requested but is not declared by this component. Declared: \
                 [{}]. Add it to the component's secret manifest, or stop requesting it -- a \
                 provider that answered undeclared names would give every component the whole \
                 store.",
                declared.join(", ")
            ),
            Self::Unresolvable { name, provider } => write!(
                f,
                "secret {name:?} is declared but the {provider} provider has no entry for it. \
                 There is no default and no empty fallback: a component that continued here would \
                 authenticate with a blank credential."
            ),
            Self::Provider { name, provider, detail } => {
                write!(f, "the {provider} provider failed resolving {name:?}: {detail}")
            }
        }
    }
}

impl std::error::Error for SecretError {}
