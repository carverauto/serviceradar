//! Why no configuration could be returned. Every variant names its source.

use crate::types::Source;
use serviceradar_config_validator::Violation;
use std::fmt;

#[derive(Debug)]
pub enum LoadError {
    /// The selector named a built-in this release does not carry.
    UnknownBuiltIn { name: String, available: Vec<String> },
    Read { source: Source, detail: String },
    Decode { source: Source, detail: String },
    /// A rule names a field the schema lacks. Distinct from a violation: the rule set is itself
    /// wrong, so no instance can be judged against it.
    RuleSet { detail: String },
    Invalid { source: Source, violations: Vec<Violation> },
    /// The artifact does not describe the environment that was selected.
    IdentityMismatch { selected: String, found: String, source: Source },
}

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
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
                "SERVICERADAR_ENV={selected} but {source} describes {found}. The wrong artifact \
                 is mounted: this component would connect to {found}'s database believing it is \
                 {selected}."
            ),
        }
    }
}

impl std::error::Error for LoadError {}
