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

/// PEM for the CA the server certificate chains to. Content, never a path: a path is only
/// meaningful on the host that resolves it, which is the assumption that stops a test action
/// from running anywhere but one machine.
pub const DATABASE_CA_CERT: &str = "database.ca_cert";

/// PEM client certificate, for a server that requires mutual TLS.
pub const DATABASE_CLIENT_CERT: &str = "database.client_cert";

/// PEM private key matching [`DATABASE_CLIENT_CERT`].
pub const DATABASE_CLIENT_KEY: &str = "database.client_key";
