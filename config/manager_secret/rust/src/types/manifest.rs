//! What a component is allowed to ask for.

use std::collections::BTreeSet;

/// The logical secret names a component declares.
///
/// The provider refuses anything undeclared. Configuration gets least privilege from the build
/// graph -- a target that does not declare a section cannot see it -- but a secret cannot be a
/// build target, so the symmetric mechanism is this declaration, enforced at the provider
/// (design.md Decision 6).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    names: BTreeSet<String>,
}

impl Manifest {
    pub fn new<I, S>(names: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self { names: names.into_iter().map(Into::into).collect() }
    }

    pub fn declares(&self, name: &str) -> bool {
        self.names.contains(name)
    }

    /// Every declared name, sorted. Used to make a refusal actionable rather than merely a "no".
    pub fn declared(&self) -> Vec<&str> {
        self.names.iter().map(String::as_str).collect()
    }

    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }
}
