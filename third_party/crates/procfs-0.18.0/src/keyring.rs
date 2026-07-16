use super::{Current, ProcResult};
use procfs_core::keyring::*;
use std::collections::HashMap;

impl Current for Keys {
    const PATH: &'static str = "/proc/keys";
}

/// Returns a list of the keys for which the reading thread has **view** permission, providing
/// various information about each key.
pub fn keys() -> ProcResult<Vec<Key>> {
    Keys::current().map(|k| k.0)
}

impl Current for KeyUsers {
    const PATH: &'static str = "/proc/key-users";
}

/// Get various information for each user ID that has at least one key on the system.
pub fn key_users() -> ProcResult<HashMap<u32, KeyUser>> {
    KeyUsers::current().map(|k| k.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keys() {
        for key in keys().unwrap() {
            println!("{:#?}", key);
        }
    }

    #[test]
    fn test_key_users() {
        for (_user, data) in key_users().unwrap() {
            println!("{:#?}", data);
        }
    }
}
