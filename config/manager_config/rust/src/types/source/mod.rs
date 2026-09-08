//! Where the bytes for an identity come from.

use crate::types::Identity;

/// Where a deployed environment's instance is mounted.
///
/// A constant, not a variable. The platform decides WHICH environment a container is by setting
/// `SERVICERADAR_ENV` and mounts the matching artifact here; making the path settable too would
/// add a second thing that can disagree with the first, which the identity check exists to catch
/// rather than to permit.
pub const MOUNTED_INSTANCE_PATH: &str = "/etc/serviceradar/environment.binpb";

/// `localhost` and `ci` carry their instance in the artifact because neither has a platform to
/// mount anything: a developer running a binary directly and a Bazel test action both have a
/// filesystem nobody provisioned. Every deployed kind reads the mount.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    BuiltIn { name: String },
    Mounted { path: String },
}

impl Source {
    pub fn for_identity(identity: &Identity) -> Self {
        match identity.kind() {
            "localhost" | "ci" => Self::BuiltIn { name: identity.to_string() },
            _ => Self::Mounted { path: MOUNTED_INSTANCE_PATH.to_string() },
        }
    }
}

mod source_display;
