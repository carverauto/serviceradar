use rand_core::{CryptoRng, RngCore};

// We use this generator only as a type parameter for the `rsa::hazmat::rsa_decrypt_and_check` function.
pub(crate) struct Dummy;

impl RngCore for Dummy {
    fn next_u32(&mut self) -> u32 {
        0
    }

    fn next_u64(&mut self) -> u64 {
        0
    }

    fn fill_bytes(&mut self, _: &mut [u8]) {}
}

impl CryptoRng for Dummy {}
