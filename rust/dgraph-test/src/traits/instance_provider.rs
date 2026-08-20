//! How an endpoint is made usable.

use crate::errors::fixture_error::FixtureError;
use crate::types::endpoint::Endpoint;

/// Make [`Endpoint`] serve, and return only once it does.
///
/// Static dispatch throughout: both implementations are zero-sized and `acquire` is called from
/// exactly one `match`, so each arm monomorphises and nothing is boxed.
pub trait InstanceProvider {
    /// The port the instance ended up on, and a container id when one was created.
    ///
    /// The port is returned rather than assumed because `docker_utils` is authoritative about
    /// where a container landed.
    fn acquire(&self, endpoint: &Endpoint) -> Result<(u16, Option<String>), FixtureError>;
}
