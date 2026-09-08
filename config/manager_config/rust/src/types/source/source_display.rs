//! How a source is named in diagnostics: a built-in by its identity, a mount by its path.

use crate::types::Source;
use std::fmt;

impl fmt::Display for Source {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BuiltIn { name } => write!(f, "built-in:{name}"),
            Self::Mounted { path } => write!(f, "{path}"),
        }
    }
}
