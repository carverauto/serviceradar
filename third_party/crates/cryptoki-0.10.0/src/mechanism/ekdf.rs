// Copyright 2023 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Mechanisms of key derivation by data encryption
//! See: <https://docs.oasis-open.org/pkcs11/pkcs11-spec/v3.1/os/pkcs11-spec-v3.1-os.html#_Toc111203514>

use std::{convert::TryInto, marker::PhantomData, slice};

/// AES CBC derivation parameters.
///
/// The mechanisms will function by performing the encryption over the data provided using the base
/// key. The resulting cipher text shall be used to create the key value of the resulting key.
///
/// This structure wraps a `CK_AES_CBC_ENCRYPT_DATA_PARAMS` structure.
#[derive(Debug, Clone, Copy)]
#[repr(transparent)]
pub struct AesCbcDeriveParams<'a> {
    inner: cryptoki_sys::CK_AES_CBC_ENCRYPT_DATA_PARAMS,

    /// Marker type to ensure we don't outlive the data
    _marker: PhantomData<&'a [u8]>,
}

impl<'a> AesCbcDeriveParams<'a> {
    /// Construct parameters for key derivation via encryption (EKDF).
    ///
    /// # Arguments
    ///
    /// * `iv` - The initialization vector
    ///
    /// * `data` - Data that will be encryption with the base key to obtain
    ///   the new key from the resulted cypher.
    pub fn new(iv: [u8; 16], data: &'a [u8]) -> Self {
        Self {
            inner: cryptoki_sys::CK_AES_CBC_ENCRYPT_DATA_PARAMS {
                iv,
                pData: data.as_ptr() as *mut _,
                length: data
                    .len()
                    .try_into()
                    .expect("data length does not fit in CK_ULONG"),
            },
            _marker: PhantomData,
        }
    }

    /// The initialization vector.
    pub fn iv(&self) -> &'a [u8] {
        unsafe { slice::from_raw_parts(self.inner.iv.as_ptr(), self.inner.iv.len()) }
    }

    /// The data.
    pub fn data(&self) -> &'a [u8] {
        unsafe { slice::from_raw_parts(self.inner.pData, self.inner.length as _) }
    }
}
