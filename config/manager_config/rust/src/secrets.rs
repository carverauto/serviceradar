//! The logical names of the secrets a database connection needs.
//!
//! Names, not values: `SecretManager` resolves each through the provider its environment
//! selects. They live here rather than in any one consumer because two components resolving
//! "the database password" must ask for the SAME name -- `//rust/integration-db` and
//! `//rust/srql` previously could not, because the constants were private to the fixture crate.
//!
//! They mirror `DatabaseConfig` in the schema, which carries every part of a connection that is
//! NOT secret -- host, port, roles, TLS mode, server name. Anything a certificate or password
//! could be recovered from belongs here instead.

/// The password for `DatabaseConfig.connecting_role`.
pub const DATABASE_PASSWORD: &str = "database.password";

/// The password for `DatabaseConfig.admin_role`.
///
/// Separate from [`DATABASE_PASSWORD`] because the roles are separate: the suite connects as
/// the application role, which deliberately lacks CREATEDB, while creating and dropping the
/// per-run database needs one that does not. One password for both would either give the
/// application role rights it must not have, or leave the lifecycle unable to provision.
pub const DATABASE_ADMIN_PASSWORD: &str = "database.admin_password";

/// PEM for the CA the server certificate chains to. Content, never a path: a path is only
/// meaningful on the host that resolves it, which is the assumption that stops a test action
/// from running anywhere but one machine.
pub const DATABASE_CA_CERT: &str = "database.ca_cert";

/// PEM for the CA the Dgraph Alpha certificate chains to.
///
/// Separate from [`DATABASE_CA_CERT`] because they are separate trust decisions: Dgraph is
/// issued by an in-cluster CA for a `*.svc.cluster.local` name no public authority will sign,
/// and dgraph-client verifies against this CA INSTEAD OF the system roots. Sharing one
/// constant would silently widen whichever of the two has the weaker issuer.
pub const DGRAPH_CA_CERT: &str = "dgraph.ca_cert";

/// The ACL credential a test uses inside its own namespace.
///
/// Split from the admin credential for the same reason the database's is: creating and dropping
/// a namespace is a different privilege from reading and writing inside one, and a scenario bug
/// holding only this one cannot destroy another run's namespace.
pub const DGRAPH_PASSWORD: &str = "dgraph.password";

/// The ACL credential for namespace 0, the only identity that may create or drop a namespace.
pub const DGRAPH_ADMIN_PASSWORD: &str = "dgraph.admin_password";

/// PEM client certificate, for a server that requires mutual TLS.
pub const DATABASE_CLIENT_CERT: &str = "database.client_cert";

/// PEM private key matching [`DATABASE_CLIENT_CERT`].
pub const DATABASE_CLIENT_KEY: &str = "database.client_key";
