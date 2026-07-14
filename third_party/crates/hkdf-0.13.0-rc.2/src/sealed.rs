use hmac::digest::{
    Digest, FixedOutput, KeyInit, Output, Update,
    block_api::{BlockSizeUser, OutputSizeUser},
};
use hmac::{EagerHash, Hmac, SimpleHmac};

pub trait Sealed<H: OutputSizeUser> {
    fn new_from_slice(key: &[u8]) -> Self;

    fn update(&mut self, data: &[u8]);

    fn finalize(self) -> Output<H>;
}

impl<H: EagerHash> Sealed<H> for Hmac<H> {
    #[inline(always)]
    fn new_from_slice(key: &[u8]) -> Self {
        KeyInit::new_from_slice(key).expect("HMAC can take a key of any size")
    }

    #[inline(always)]
    fn update(&mut self, data: &[u8]) {
        Update::update(self, data);
    }

    #[inline(always)]
    #[allow(deprecated)] // clone_from_slice
    fn finalize(self) -> Output<H> {
        // Output<H> and Output<H::Core> are always equal to each other,
        // but we can not prove it at type level
        Output::<H>::clone_from_slice(&self.finalize_fixed())
    }
}

impl<H: Digest + BlockSizeUser + Clone> Sealed<H> for SimpleHmac<H> {
    #[inline(always)]
    fn new_from_slice(key: &[u8]) -> Self {
        KeyInit::new_from_slice(key).expect("HMAC can take a key of any size")
    }

    #[inline(always)]
    fn update(&mut self, data: &[u8]) {
        Update::update(self, data);
    }

    #[inline(always)]
    #[allow(deprecated)] // clone_from_slice
    fn finalize(self) -> Output<H> {
        // Output<H> and Output<H::Core> are always equal to each other,
        // but we can not prove it at type level
        Output::<H>::clone_from_slice(&self.finalize_fixed())
    }
}
