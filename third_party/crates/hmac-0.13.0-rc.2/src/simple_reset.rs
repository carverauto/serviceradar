use crate::utils::{IPAD, OPAD, get_der_key};
use core::fmt;
use digest::{
    Digest, FixedOutput, KeyInit, MacMarker, Output, OutputSizeUser, Update,
    crypto_common::{Block, BlockSizeUser, InvalidLength, Key, KeySizeUser},
};
use digest::{FixedOutputReset, Reset};

/// Simplified HMAC instance with reset support able to operate
/// over hash functions which do not expose block-level API and
/// hash functions which process blocks lazily (e.g. BLAKE2).
#[derive(Clone)]
pub struct SimpleHmacReset<D: Digest + BlockSizeUser> {
    digest: D,
    opad_key: Block<D>,
    ipad_key: Block<D>,
}

impl<D: Digest + BlockSizeUser> KeySizeUser for SimpleHmacReset<D> {
    type KeySize = D::BlockSize;
}

impl<D: Digest + BlockSizeUser> MacMarker for SimpleHmacReset<D> {}

impl<D: Digest + BlockSizeUser> KeyInit for SimpleHmacReset<D> {
    fn new(key: &Key<Self>) -> Self {
        Self::new_from_slice(key.as_slice()).unwrap()
    }

    #[inline]
    fn new_from_slice(key: &[u8]) -> Result<Self, InvalidLength> {
        let der_key = get_der_key::<D>(key);

        let mut ipad_key = der_key.clone();
        ipad_key.iter_mut().for_each(|b: &mut u8| *b ^= IPAD);

        let mut digest = D::new();
        digest.update(&ipad_key);

        let mut opad_key = der_key;
        opad_key.iter_mut().for_each(|b: &mut u8| *b ^= OPAD);

        Ok(Self {
            digest,
            opad_key,
            ipad_key,
        })
    }
}

impl<D: Digest + BlockSizeUser> Update for SimpleHmacReset<D> {
    #[inline(always)]
    fn update(&mut self, data: &[u8]) {
        self.digest.update(data);
    }
}

impl<D: Digest + BlockSizeUser> OutputSizeUser for SimpleHmacReset<D> {
    type OutputSize = D::OutputSize;
}

impl<D: Digest + BlockSizeUser> FixedOutput for SimpleHmacReset<D> {
    fn finalize_into(self, out: &mut Output<Self>) {
        let mut h = D::new();
        h.update(&self.opad_key);
        h.update(self.digest.finalize());
        h.finalize_into(out);
    }
}

impl<D: Digest + BlockSizeUser + fmt::Debug> fmt::Debug for SimpleHmacReset<D> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SimpleResetHmac")
    }
}

impl<D: Digest + BlockSizeUser + Reset> Reset for SimpleHmacReset<D> {
    fn reset(&mut self) {
        Reset::reset(&mut self.digest);
        self.digest.update(&self.ipad_key);
    }
}

impl<D: Digest + BlockSizeUser + FixedOutputReset> FixedOutputReset for SimpleHmacReset<D> {
    fn finalize_into_reset(&mut self, out: &mut Output<Self>) {
        let mut h = D::new();
        Update::update(&mut h, &self.opad_key);
        Update::update(&mut h, &self.digest.finalize_reset());
        Update::update(&mut self.digest, &self.ipad_key);
        Digest::finalize_into(h, out);
    }
}
