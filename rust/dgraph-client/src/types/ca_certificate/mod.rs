/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use std::path::PathBuf;

/// A certificate authority to verify the server against, instead of the system trust store.
///
/// Two sources because the two callers differ. A connection string carries a PATH: a PEM does
/// not fit in a URL, and in Kubernetes the CA arrives as a mounted file, which is also what
/// libpq's `sslrootcert` and Dgraph's own `--tls ca-cert=` accept. Code that already holds the
/// bytes -- anything resolving it through SecretManager, which yields content rather than a
/// location -- supplies PEM directly and never touches the filesystem.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum CaCertificate {
    /// PEM bytes, already in memory.
    Pem(Vec<u8>),
    /// A path read when the channel is built, so a missing file fails at connect rather than
    /// at parse -- the same point where an unreachable endpoint fails.
    File(PathBuf),
}

impl CaCertificate {
    /// The PEM bytes, reading the file if this is a [`CaCertificate::File`].
    pub fn pem(&self) -> Result<Vec<u8>, std::io::Error> {
        match self {
            Self::Pem(bytes) => Ok(bytes.clone()),
            Self::File(path) => std::fs::read(path),
        }
    }
}
