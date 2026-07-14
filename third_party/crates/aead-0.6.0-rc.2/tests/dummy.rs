//! This module defines dummy (horribly insecure!) AEAD implementations
//! to test implementation of the AEAD traits and helper macros in the `dev` module.
#![cfg(feature = "dev")]
use aead::{
    AeadCore, AeadInOut, Error, Key, KeyInit, KeySizeUser, Nonce, Result, Tag, TagPosition,
    array::Array, consts::U8,
};
use inout::InOutBuf;

struct DummyAead {
    key: [u8; 8],
}

impl DummyAead {
    fn process_aad(&self, nonce: &[u8; 8], aad: &[u8]) -> u64 {
        let mut tag = u64::from_le_bytes(*nonce);
        let key = u64::from_le_bytes(self.key);

        let mut aad_iter = aad.chunks_exact(8);
        for chunk in &mut aad_iter {
            tag ^= u64::from_le_bytes(chunk.try_into().unwrap());
            tag = tag.wrapping_add(key);
        }
        let aad_rem = aad_iter.remainder();
        if !aad_rem.is_empty() {
            let mut chunk = [0u8; 8];
            chunk[..aad_rem.len()].copy_from_slice(aad_rem);
            tag ^= u64::from_le_bytes(chunk);
            tag = tag.wrapping_add(key);
        }

        tag
    }

    fn encrypt_inner(
        &self,
        nonce: &[u8; 8],
        aad: &[u8],
        buffer: InOutBuf<'_, '_, u8>,
    ) -> Result<[u8; 8]> {
        let mut tag = self.process_aad(nonce, aad);

        let (blocks, mut rem) = buffer.into_chunks::<U8>();
        for mut block in blocks {
            block.xor_in2out(&self.key.into());
            tag ^= u64::from_be_bytes(block.get_out().0);
        }

        if !rem.is_empty() {
            rem.xor_in2out(&self.key[..rem.len()]);

            let out_rem = rem.get_out();
            let mut block = [0u8; 8];
            block[..out_rem.len()].copy_from_slice(out_rem);
            tag ^= u64::from_le_bytes(block);
        }

        Ok(tag.to_le_bytes())
    }

    fn decrypt_inner(
        &self,
        nonce: &[u8; 8],
        aad: &[u8],
        mut buffer: InOutBuf<'_, '_, u8>,
        tag: &[u8; 8],
    ) -> Result<()> {
        let exp_tag = u64::from_le_bytes(*tag);
        let mut tag = self.process_aad(nonce, aad);

        let (blocks, mut rem) = buffer.reborrow().into_chunks::<U8>();
        for mut block in blocks {
            tag ^= u64::from_be_bytes(block.get_in().0);
            block.xor_in2out(&self.key.into());
        }

        if !rem.is_empty() {
            let in_rem = rem.get_in();
            let mut block = [0u8; 8];
            block[..in_rem.len()].copy_from_slice(in_rem);
            tag ^= u64::from_le_bytes(block);

            rem.xor_in2out(&self.key[..rem.len()]);
        }

        if tag == exp_tag {
            Ok(())
        } else {
            buffer.get_out().fill(0);
            Err(Error)
        }
    }
}

pub struct PrefixDummyAead(DummyAead);

impl KeySizeUser for PrefixDummyAead {
    type KeySize = U8;
}

impl KeyInit for PrefixDummyAead {
    fn new(key: &Key<Self>) -> Self {
        Self(DummyAead { key: key.0 })
    }
}

impl AeadCore for PrefixDummyAead {
    type NonceSize = U8;
    type TagSize = U8;
    const TAG_POSITION: TagPosition = TagPosition::Prefix;
}

impl AeadInOut for PrefixDummyAead {
    fn encrypt_inout_detached(
        &self,
        nonce: &Nonce<Self>,
        aad: &[u8],
        buffer: InOutBuf<'_, '_, u8>,
    ) -> Result<Tag<Self>> {
        self.0.encrypt_inner(nonce.into(), aad, buffer).map(Array)
    }

    fn decrypt_inout_detached(
        &self,
        nonce: &Nonce<Self>,
        aad: &[u8],
        buffer: InOutBuf<'_, '_, u8>,
        tag: &Tag<Self>,
    ) -> Result<()> {
        self.0.decrypt_inner(nonce.into(), aad, buffer, tag.into())
    }
}

pub struct PostfixDummyAead(DummyAead);

impl KeySizeUser for PostfixDummyAead {
    type KeySize = U8;
}

impl KeyInit for PostfixDummyAead {
    fn new(key: &Key<Self>) -> Self {
        Self(DummyAead { key: key.0 })
    }
}

impl AeadCore for PostfixDummyAead {
    type NonceSize = U8;
    type TagSize = U8;
    const TAG_POSITION: TagPosition = TagPosition::Postfix;
}

impl AeadInOut for PostfixDummyAead {
    fn encrypt_inout_detached(
        &self,
        nonce: &Nonce<Self>,
        aad: &[u8],
        buffer: InOutBuf<'_, '_, u8>,
    ) -> Result<Tag<Self>> {
        self.0.encrypt_inner(nonce.into(), aad, buffer).map(Array)
    }

    fn decrypt_inout_detached(
        &self,
        nonce: &Nonce<Self>,
        aad: &[u8],
        buffer: InOutBuf<'_, '_, u8>,
        tag: &Tag<Self>,
    ) -> Result<()> {
        self.0.decrypt_inner(nonce.into(), aad, buffer, tag.into())
    }
}

aead::new_test!(dummy_prefix, "prefix", PrefixDummyAead);
aead::new_test!(dummy_postfix, "postfix", PostfixDummyAead);
