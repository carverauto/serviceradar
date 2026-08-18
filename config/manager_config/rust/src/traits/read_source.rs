//! Reading the mounted artifact.

/// Reads bytes for a mounted source.
///
/// A trait so the manager never decides how a deployment reaches its own configuration. That is
/// what keeps the bootstrap acyclic: were this fixed here and were it ever to need a credential,
/// the credential would come from SecretManager, which needs configuration to know its provider
/// (design.md Decision 12).
pub trait ReadSource {
    fn read(&self, path: &str) -> Result<Vec<u8>, String>;
}

/// The default: a mounted file, which arrives over the same trust path as the container image.
#[derive(Debug, Default, Clone, Copy)]
pub struct Filesystem;

impl ReadSource for Filesystem {
    fn read(&self, path: &str) -> Result<Vec<u8>, String> {
        std::fs::read(path).map_err(|e| e.to_string())
    }
}
