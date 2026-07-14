use crate::utils::{IPAD, OPAD, get_der_key};
use core::{fmt, slice};
use digest::{
    InvalidLength, KeyInit, MacMarker, Output, Reset,
    block_api::{
        AlgorithmName, Block, BlockSizeUser, Buffer, BufferKindUser, EagerHash, FixedOutputCore,
        OutputSizeUser, UpdateCore,
    },
    block_buffer::Eager,
    crypto_common::{Key, KeySizeUser},
};

/// Generic core HMAC instance, which operates over blocks.
pub struct HmacCore<D: EagerHash> {
    digest: D::Core,
    opad_digest: D::Core,
}

impl<D: EagerHash> Clone for HmacCore<D> {
    fn clone(&self) -> Self {
        Self {
            digest: self.digest.clone(),
            opad_digest: self.opad_digest.clone(),
        }
    }
}

impl<D: EagerHash> MacMarker for HmacCore<D> {}

impl<D: EagerHash> BufferKindUser for HmacCore<D> {
    type BufferKind = Eager;
}

impl<D: EagerHash> KeySizeUser for HmacCore<D> {
    type KeySize = <<D as EagerHash>::Core as BlockSizeUser>::BlockSize;
}

impl<D: EagerHash> BlockSizeUser for HmacCore<D> {
    type BlockSize = <<D as EagerHash>::Core as BlockSizeUser>::BlockSize;
}

impl<D: EagerHash> OutputSizeUser for HmacCore<D> {
    type OutputSize = <<D as EagerHash>::Core as OutputSizeUser>::OutputSize;
}

impl<D: EagerHash> KeyInit for HmacCore<D> {
    #[inline(always)]
    fn new(key: &Key<Self>) -> Self {
        Self::new_from_slice(key.as_slice()).unwrap()
    }

    #[inline(always)]
    fn new_from_slice(key: &[u8]) -> Result<Self, InvalidLength> {
        let mut buf = get_der_key::<D>(key);
        buf.iter_mut().for_each(|b: &mut u8| *b ^= IPAD);

        let mut digest = D::Core::default();
        digest.update_blocks(slice::from_ref(&buf));

        buf.iter_mut().for_each(|b: &mut u8| *b ^= IPAD ^ OPAD);

        let mut opad_digest = D::Core::default();
        opad_digest.update_blocks(slice::from_ref(&buf));

        Ok(Self {
            opad_digest,
            digest,
        })
    }
}

impl<D: EagerHash> UpdateCore for HmacCore<D> {
    #[inline(always)]
    fn update_blocks(&mut self, blocks: &[Block<Self>]) {
        self.digest.update_blocks(blocks);
    }
}

impl<D: EagerHash> FixedOutputCore for HmacCore<D> {
    #[inline(always)]
    fn finalize_fixed_core(&mut self, buffer: &mut Buffer<Self>, out: &mut Output<Self>) {
        let mut hash = Output::<D::Core>::default();
        self.digest.finalize_fixed_core(buffer, &mut hash);
        // finalize_fixed_core should reset the buffer as well, but
        // to be extra safe we reset it explicitly again.
        buffer.reset();
        let h = &mut self.opad_digest;
        buffer.digest_blocks(&hash, |b| h.update_blocks(b));
        h.finalize_fixed_core(buffer, out);
    }
}

impl<D: EagerHash + AlgorithmName> AlgorithmName for HmacCore<D> {
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Hmac<")?;
        <D as AlgorithmName>::write_alg_name(f)?;
        f.write_str(">")
    }
}

impl<D: EagerHash> fmt::Debug for HmacCore<D>
where
    D::Core: AlgorithmName,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("HmacCore { ... }")
    }
}

/// Generic core HMAC instance, which operates over blocks.
pub struct HmacResetCore<D: EagerHash> {
    digest: D::Core,
    opad_digest: D::Core,
    ipad_digest: D::Core,
}

impl<D: EagerHash> Clone for HmacResetCore<D> {
    fn clone(&self) -> Self {
        Self {
            digest: self.digest.clone(),
            opad_digest: self.opad_digest.clone(),
            ipad_digest: self.ipad_digest.clone(),
        }
    }
}

impl<D: EagerHash> MacMarker for HmacResetCore<D> {}

impl<D: EagerHash> BufferKindUser for HmacResetCore<D> {
    type BufferKind = Eager;
}

impl<D: EagerHash> KeySizeUser for HmacResetCore<D> {
    type KeySize = <<D as EagerHash>::Core as BlockSizeUser>::BlockSize;
}

impl<D: EagerHash> BlockSizeUser for HmacResetCore<D> {
    type BlockSize = <<D as EagerHash>::Core as BlockSizeUser>::BlockSize;
}

impl<D: EagerHash> OutputSizeUser for HmacResetCore<D> {
    type OutputSize = <<D as EagerHash>::Core as OutputSizeUser>::OutputSize;
}

impl<D: EagerHash> KeyInit for HmacResetCore<D> {
    #[inline(always)]
    fn new(key: &Key<Self>) -> Self {
        Self::new_from_slice(key.as_slice()).unwrap()
    }

    #[inline(always)]
    fn new_from_slice(key: &[u8]) -> Result<Self, InvalidLength> {
        let mut buf = get_der_key::<D>(key);
        buf.iter_mut().for_each(|b: &mut u8| *b ^= IPAD);

        let mut digest = D::Core::default();
        digest.update_blocks(slice::from_ref(&buf));

        buf.iter_mut().for_each(|b: &mut u8| *b ^= IPAD ^ OPAD);

        let mut opad_digest = D::Core::default();
        opad_digest.update_blocks(slice::from_ref(&buf));

        Ok(Self {
            ipad_digest: digest.clone(),
            opad_digest,
            digest,
        })
    }
}

impl<D: EagerHash> UpdateCore for HmacResetCore<D> {
    #[inline(always)]
    fn update_blocks(&mut self, blocks: &[Block<Self>]) {
        self.digest.update_blocks(blocks);
    }
}

impl<D: EagerHash> FixedOutputCore for HmacResetCore<D> {
    #[inline(always)]
    fn finalize_fixed_core(&mut self, buffer: &mut Buffer<Self>, out: &mut Output<Self>) {
        let mut hash = Output::<D::Core>::default();
        self.digest.finalize_fixed_core(buffer, &mut hash);
        // finalize_fixed_core should reset the buffer as well, but
        // to be extra safe we reset it explicitly again.
        buffer.reset();
        let mut h = self.opad_digest.clone();
        buffer.digest_blocks(&hash, |b| h.update_blocks(b));
        h.finalize_fixed_core(buffer, out);
    }
}

impl<D: EagerHash> Reset for HmacResetCore<D> {
    #[inline(always)]
    fn reset(&mut self) {
        self.digest = self.ipad_digest.clone();
    }
}

impl<D: EagerHash + AlgorithmName> AlgorithmName for HmacResetCore<D> {
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Hmac<")?;
        <D as AlgorithmName>::write_alg_name(f)?;
        f.write_str(">")
    }
}

impl<D: EagerHash> fmt::Debug for HmacResetCore<D>
where
    D::Core: AlgorithmName,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("HmacResetCore { ... }")
    }
}
