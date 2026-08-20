//! Whether this process owns the Dgraph it was handed.

/// Ownership of the instance, which is what decides whether wiping it is acceptable.
///
/// Not derivable from the endpoint: `localhost:9080` and a cluster service name are both just
/// addresses. Only the strategy that produced the instance knows whether anyone else is using it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Exclusivity {
    /// This process created it, so its contents may be destroyed.
    Exclusive,
    /// Someone else owns it -- concurrent pull requests share the CI fixture. Read freely;
    /// never wipe.
    Shared,
}

impl Exclusivity {
    /// True when destroying the instance's contents affects nobody else.
    pub fn may_destroy(self) -> bool {
        matches!(self, Self::Exclusive)
    }
}
