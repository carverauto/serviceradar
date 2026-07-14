// Copyright 2023 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! AEAD block cipher mechanism types

use crate::error::Error;
use crate::types::Ulong;
use cryptoki_sys::*;
use std::convert::TryInto;
use std::marker::PhantomData;
use std::slice;

/// Parameters for AES-GCM.
#[derive(Debug)]
#[repr(transparent)]
pub struct GcmParams<'a> {
    inner: CK_GCM_PARAMS,
    _marker: PhantomData<&'a mut [u8]>,
}

impl<'a> GcmParams<'a> {
    /// Construct GCM parameters.
    ///
    /// # Arguments
    ///
    /// `iv` - The initialization vector.  This must be non-empty.  In PKCS#11
    /// 2.40, the maximum length of the IV is 256 bytes.  A 12-byte IV may be
    /// processed more efficiently than other lengths.
    ///
    /// `aad` - The additional authenticated data.  This data is authenticated
    /// but not encrypted.  This may be between 0 and 2^32-1 bytes.
    ///
    /// `tag_bits` - The length, in **bits**, of the authentication tag.  Must
    /// be between 0 and 128.  The tag is appended to the end of the
    /// ciphertext.
    /// # Errors
    /// This function returns an error if the length of `iv` or `aad` does not
    /// fit into an [Ulong].
    pub fn new(iv: &'a mut [u8], aad: &'a [u8], tag_bits: Ulong) -> Result<Self, Error> {
        // The ulIvBits parameter seems to be missing from the 2.40 spec,
        // although it is included in the header file.  In [1], OASIS clarified
        // that the header file is normative.  In 3.0, they added the parameter
        // to the spec, but it seems to be unused:
        //
        // > Do not use ulIvBits to specify the length of the initialization
        // > vector, but ulIvLen instead.
        //
        // Further, in v3.0, the IV is permitted to be up to 2^32-1 bytes,
        // which would cause ulIvBits to overflow on platforms where
        // sizeof(CK_ULONG) = 4.
        //
        // In light of all this, we include ulIvBits in the struct, but always
        // set it to zero.
        //
        // [1]: https://www.oasis-open.org/committees/document.php?document_id=58032&wg_abbrev=pkcs11

        let iv_len = iv.len();
        // Some HSMs may require the ulIvBits field to be populated, while others don't pay attention to it.
        let iv_bit_len = iv_len * 8;

        Ok(GcmParams {
            inner: CK_GCM_PARAMS {
                pIv: iv.as_mut_ptr(),
                ulIvLen: iv_len.try_into()?,
                // Since this field isn't universally used, set it to 0 if it doesn't fit in CK_ULONG.
                // If the HSM doesn't require the field, it won't mind; and it it does, it would break anyways.
                ulIvBits: iv_bit_len.try_into().unwrap_or_default(),
                pAAD: aad.as_ptr() as *mut _,
                ulAADLen: aad.len().try_into()?,
                ulTagBits: tag_bits.into(),
            },
            _marker: PhantomData,
        })
    }

    /// The initialization vector.
    pub fn iv(&mut self) -> &mut [u8] {
        // SAFETY: In the constructor, the IV always comes from a &'a mut [u8]
        unsafe { slice::from_raw_parts_mut(self.inner.pIv, self.inner.ulIvLen as _) }
    }

    /// The additional authenticated data.
    pub fn aad(&self) -> &'a [u8] {
        // SAFETY: In the constructor, the AAD always comes from a &'a [u8]
        unsafe { slice::from_raw_parts(self.inner.pAAD, self.inner.ulAADLen as _) }
    }

    /// The length, in bits, of the authentication tag.
    pub fn tag_bits(&self) -> Ulong {
        self.inner.ulTagBits.into()
    }
}

/// The GCM generator function for the Initialization Vector
#[derive(Debug, Clone, Copy)]
pub enum GeneratorFunction {
    /// `CKG_NO_GENERATE` no IV generation is done.
    NoGenerate,
    /// `CKG_GENERATE` the non-fixed part of IV is generated internally
    Generate,
    /// `CKG_GENERATE_COUNTER` the non-fixed part of IV is generated internally by incrementing
    /// counter. Initially zero.
    GenerateCounter,
    /// `CKG_GENERATE_RANDOM` the non-fixed part of IV is generated internally by PRNG
    GenerateRandom,
    /// `CKG_GENERATE_COUNTER_XOR` the non-fixed part of IV xored with incrementing counter.
    GenerateCounterXor,
}

/// Parameters for message based AES-GCM operations.
#[derive(Debug, Copy, Clone)]
#[repr(transparent)]
pub struct GcmMessageParams<'a> {
    inner: CK_GCM_MESSAGE_PARAMS,
    _marker: PhantomData<&'a mut [u8]>,
}

impl<'a> GcmMessageParams<'a> {
    /// Construct GCM parameters for message based operations
    ///
    /// # Arguments
    ///
    /// `iv` - The initialization vector.  This must be non-empty.  In PKCS#11
    /// 3.0, the maximum length of the IV is 256 bytes.  A 12-byte IV may be
    /// processed more efficiently than other lengths.
    ///
    /// `iv_fixed_bits` - number of bits of the original IV to preserve when
    /// generating an new IV. These bits are counted from the Most significant
    /// bits (to the right).
    ///
    /// `iv_generator` - Function used to generate a new IV. Each IV must be
    /// unique for a given session.
    ///
    /// `tag` - The buffer to store the tag. Either to be passed in or returned if generated by
    /// token.
    ///
    /// # Errors
    /// This function returns an error if the length of `iv` does not
    /// fit into an [Ulong].
    pub fn new(
        iv: &'a mut [u8],
        iv_fixed_bits: Ulong,
        iv_generator: GeneratorFunction,
        tag: &'a mut [u8],
    ) -> Result<Self, Error> {
        let tag_bits = tag.len() * 8;
        Ok(GcmMessageParams {
            inner: CK_GCM_MESSAGE_PARAMS {
                pIv: iv.as_mut_ptr(),
                ulIvLen: iv.len().try_into()?,
                ulIvFixedBits: iv_fixed_bits.into(),
                ivGenerator: match iv_generator {
                    GeneratorFunction::NoGenerate => CKG_NO_GENERATE,
                    GeneratorFunction::Generate => CKG_GENERATE,
                    GeneratorFunction::GenerateCounter => CKG_GENERATE_COUNTER,
                    GeneratorFunction::GenerateRandom => CKG_GENERATE_RANDOM,
                    GeneratorFunction::GenerateCounterXor => CKG_GENERATE_COUNTER_XOR,
                },
                pTag: tag.as_mut_ptr(),
                ulTagBits: tag_bits.try_into()?,
            },
            _marker: PhantomData,
        })
    }

    /// The initialization vector.
    pub fn iv(&mut self) -> &mut [u8] {
        // SAFETY: In the constructor, the IV always comes from a &'a mut [u8]
        unsafe { slice::from_raw_parts_mut(self.inner.pIv, self.inner.ulIvLen as _) }
    }

    /// The length, in bits, of fixed part of the IV.
    pub fn iv_fixed_bits(&self) -> Ulong {
        self.inner.ulIvFixedBits.into()
    }

    /// The IV generator.
    pub fn iv_generator(&self) -> GeneratorFunction {
        match self.inner.ivGenerator {
            CKG_NO_GENERATE => GeneratorFunction::NoGenerate,
            CKG_GENERATE => GeneratorFunction::Generate,
            CKG_GENERATE_COUNTER => GeneratorFunction::GenerateCounter,
            CKG_GENERATE_RANDOM => GeneratorFunction::GenerateRandom,
            CKG_GENERATE_COUNTER_XOR => GeneratorFunction::GenerateCounterXor,
            _ => unreachable!(),
        }
    }

    /// The authentication tag.
    pub fn tag(&self) -> &'a [u8] {
        // SAFETY: In the constructor, the tag always comes from a &'a [u8]
        unsafe { slice::from_raw_parts(self.inner.pTag, (self.inner.ulTagBits / 8) as _) }
    }
}
