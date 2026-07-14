//! Random numbers generation utilities required in WebSocket clients.

#[cfg(not(any(feature = "fastrand", feature = "getrandom", feature = "rand")))]
compile_error!("Using the `client` feature requires enabling a random number generator implementation via one of the following features: `fastrand`, `getrandom` or `rand`.");

/// Random numbers generation utilities using [`fastrand`].
#[cfg(all(
    feature = "fastrand",
    not(feature = "getrandom"),
    not(feature = "rand")
))]
mod imp {
    /// Generate a random 16-byte WebSocket key.
    pub fn get_key() -> [u8; 16] {
        fastrand::u128(..).to_ne_bytes()
    }

    /// Generate a random 4-byte WebSocket mask.
    pub fn get_mask() -> [u8; 4] {
        fastrand::u32(..).to_ne_bytes()
    }
}

/// Random numbers generation utilities using [`getrandom`].
#[cfg(all(feature = "getrandom", not(feature = "rand")))]
mod imp {

    /// Generate a random 16-byte WebSocket key.
    pub fn get_key() -> [u8; 16] {
        let mut bytes = [0; 16];
        getrandom::getrandom(&mut bytes).expect("Failed to get random bytes, consider using `rand` or `fastrand` instead of `getrandom` if this persists");
        bytes
    }

    /// Generate a random 4-byte WebSocket mask.
    pub fn get_mask() -> [u8; 4] {
        let mut bytes = [0; 4];
        getrandom::getrandom(&mut bytes).expect("Failed to get random bytes, consider using `rand` or `fastrand` instead of `getrandom` if this persists");
        bytes
    }
}

/// Random numbers generation utilities using [`rand`].
#[cfg(feature = "rand")]
mod imp {

    use rand::RngCore;

    /// Generate a random 16-byte WebSocket key.
    pub fn get_key() -> [u8; 16] {
        let mut bytes = [0; 16];
        rand::thread_rng().fill_bytes(&mut bytes);
        bytes
    }

    /// Generate a random 4-byte WebSocket mask.
    pub fn get_mask() -> [u8; 4] {
        let mut bytes = [0; 4];
        rand::thread_rng().fill_bytes(&mut bytes);
        bytes
    }
}

pub use imp::{get_key, get_mask};
