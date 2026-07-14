use crate::utils::{IPAD, OPAD, get_der_key};
use core::fmt;
use digest::{
    Digest, FixedOutput, KeyInit, MacMarker, Output, OutputSizeUser, Update,
    crypto_common::{Block, BlockSizeUser, InvalidLength, Key, KeySizeUser},
};

/// Simplified HMAC instance able to operate over hash functions
/// which do not expose block-level API and hash functions which
/// process blocks lazily (e.g. BLAKE2).
#[derive(Clone)]
pub struct SimpleHmac<D: Digest + BlockSizeUser> {
    digest: D,
    opad_key: Block<D>,
}

impl<D: Digest + BlockSizeUser> KeySizeUser for SimpleHmac<D> {
    type KeySize = D::BlockSize;
}

impl<D: Digest + BlockSizeUser> MacMarker for SimpleHmac<D> {}

impl<D: Digest + BlockSizeUser> KeyInit for SimpleHmac<D> {
    fn new(key: &Key<Self>) -> Self {
        Self::new_from_slice(key.as_slice()).unwrap()
    }

    #[inline]
    fn new_from_slice(key: &[u8]) -> Result<Self, InvalidLength> {
        let mut buf = get_der_key::<D>(key);
        buf.iter_mut().for_each(|b: &mut u8| *b ^= IPAD);

        let mut digest = D::new();
        digest.update(&buf);

        buf.iter_mut().for_each(|b: &mut u8| *b ^= OPAD ^ IPAD);

        Ok(Self {
            digest,
            opad_key: buf,
        })
    }
}

impl<D: Digest + BlockSizeUser> Update for SimpleHmac<D> {
    #[inline(always)]
    fn update(&mut self, data: &[u8]) {
        self.digest.update(data);
    }
}

impl<D: Digest + BlockSizeUser> OutputSizeUser for SimpleHmac<D> {
    type OutputSize = D::OutputSize;
}

impl<D: Digest + BlockSizeUser> FixedOutput for SimpleHmac<D> {
    fn finalize_into(self, out: &mut Output<Self>) {
        let mut h = D::new();
        h.update(&self.opad_key);
        h.update(self.digest.finalize());
        h.finalize_into(out);
    }
}

impl<D: Digest + BlockSizeUser + fmt::Debug> fmt::Debug for SimpleHmac<D> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SimpleHmac { ... }")
    }
}
