//! How an endpoint is made usable, chosen by environment kind.

use crate::errors::fixture_error::FixtureError;
use serviceradar_config_manager::Identity;

/// The two ways to obtain a Dgraph.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Strategy {
    /// Provision a `dgraph/standalone` container. `localhost` only.
    Container,
    /// Verify a Dgraph this process did not create. `ci`.
    Existing,
}

impl Strategy {
    /// `localhost` provisions, `ci` verifies, everything else is refused.
    ///
    /// The same axis the configuration already partitions on -- `Source::for_identity` is
    /// `match identity.kind() { "localhost" | "ci" => BuiltIn, _ => Mounted }` -- so this is a
    /// third function keyed the same way rather than a new idea.
    ///
    /// The refusal is the point, not an oversight. `saas` and `demo` both resolve to
    /// `dgraph-dgraph-alpha.dgraph.svc.cluster.local`, which is production. A fixture that hands
    /// back a live production endpoint is one careless call away from an incident, and "it only
    /// health-checks" is a property of today's code rather than of the type. One match arm makes
    /// it a guarantee instead. Adding an arm later should be a deliberate act with a name on it.
    pub fn for_identity(identity: &Identity) -> Result<Self, FixtureError> {
        match identity.kind() {
            "localhost" => Ok(Self::Container),
            "ci" => Ok(Self::Existing),
            kind => Err(FixtureError::unsupported(kind)),
        }
    }

    /// A container this process started is ours; anything pre-existing is not.
    pub fn exclusivity(self) -> crate::types::exclusivity::Exclusivity {
        use crate::types::exclusivity::Exclusivity;
        match self {
            Self::Container => Exclusivity::Exclusive,
            Self::Existing => Exclusivity::Shared,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Container => "container",
            Self::Existing => "existing",
        }
    }
}
