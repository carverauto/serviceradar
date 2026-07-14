// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! RSA mechanism types

use super::{Mechanism, MechanismType};
use crate::error::{Error, Result};
use crate::types::Ulong;
use cryptoki_sys::*;
use log::error;
use std::convert::{TryFrom, TryInto};
use std::ffi::c_void;
use std::marker::PhantomData;
use std::ops::Deref;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(transparent)]
/// Message Generation Function (MGF) applied to a message block when formatting a message block
/// for the PKCS #1 OAEP encryption scheme or the PKCS #1 PSS signature scheme.
pub struct PkcsMgfType {
    val: CK_RSA_PKCS_MGF_TYPE,
}

impl PkcsMgfType {
    /// MGF1 SHA-1
    pub const MGF1_SHA1: PkcsMgfType = PkcsMgfType { val: CKG_MGF1_SHA1 };
    /// MGF1 SHA-224
    pub const MGF1_SHA224: PkcsMgfType = PkcsMgfType {
        val: CKG_MGF1_SHA224,
    };
    /// MGF1 SHA-256
    pub const MGF1_SHA256: PkcsMgfType = PkcsMgfType {
        val: CKG_MGF1_SHA256,
    };
    /// MGF1 SHA-384
    pub const MGF1_SHA384: PkcsMgfType = PkcsMgfType {
        val: CKG_MGF1_SHA384,
    };
    /// MGF1 SHA-512
    pub const MGF1_SHA512: PkcsMgfType = PkcsMgfType {
        val: CKG_MGF1_SHA512,
    };
}

impl Deref for PkcsMgfType {
    type Target = CK_RSA_PKCS_MGF_TYPE;

    fn deref(&self) -> &Self::Target {
        &self.val
    }
}

impl From<PkcsMgfType> for CK_RSA_PKCS_MGF_TYPE {
    fn from(mgf_type: PkcsMgfType) -> Self {
        *mgf_type
    }
}

impl TryFrom<CK_RSA_PKCS_MGF_TYPE> for PkcsMgfType {
    type Error = Error;

    fn try_from(mgf_type: CK_RSA_PKCS_MGF_TYPE) -> Result<Self> {
        match mgf_type {
            CKG_MGF1_SHA1 => Ok(PkcsMgfType::MGF1_SHA1),
            CKG_MGF1_SHA224 => Ok(PkcsMgfType::MGF1_SHA224),
            CKG_MGF1_SHA256 => Ok(PkcsMgfType::MGF1_SHA256),
            CKG_MGF1_SHA384 => Ok(PkcsMgfType::MGF1_SHA384),
            CKG_MGF1_SHA512 => Ok(PkcsMgfType::MGF1_SHA512),
            other => {
                error!(
                    "Mask Generation Function type {} is not one of the valid values.",
                    other
                );
                Err(Error::InvalidValue)
            }
        }
    }
}

#[derive(Debug, Clone, Copy)]
/// Source of the encoding parameter when formatting a message block for the PKCS #1 OAEP
/// encryption scheme
pub struct PkcsOaepSource<'a>(Option<&'a [u8]>);

impl<'a> PkcsOaepSource<'a> {
    /// Construct an empty encoding parameter.
    ///
    /// This is equivalent to `data_specified(&[])`.
    pub fn empty() -> Self {
        Self(None)
    }

    /// Construct an encoding parameter from an array of bytes.
    pub fn data_specified(source_data: &'a [u8]) -> Self {
        Self(Some(source_data))
    }

    pub(crate) fn source_ptr(&self) -> *const c_void {
        if let Some(source_data) = self.0 {
            source_data.as_ptr() as _
        } else {
            std::ptr::null()
        }
    }

    pub(crate) fn source_len(&self) -> Ulong {
        self.0
            .unwrap_or_default()
            .len()
            .try_into()
            .expect("usize can not fit in CK_ULONG")
    }

    pub(crate) fn source_type(&self) -> CK_RSA_PKCS_OAEP_SOURCE_TYPE {
        CKZ_DATA_SPECIFIED
    }
}

/// Parameters of the RsaPkcsPss mechanism
#[derive(Copy, Debug, Clone)]
#[repr(C)]
pub struct PkcsPssParams {
    /// hash algorithm used in the PSS encoding; if the signature mechanism does not include
    /// message hashing, then this value must be the mechanism used by the application to generate
    /// the message hash; if the signature mechanism includes hashing, then this value must match
    /// the hash algorithm indicated by the signature mechanism
    pub hash_alg: MechanismType,
    /// mask generation function to use on the encoded block
    pub mgf: PkcsMgfType,
    /// length, in bytes, of the salt value used in the PSS encoding; typical values are the length
    /// of the message hash and zero
    pub s_len: Ulong,
}

/// Parameters of the RsaPkcsOaep mechanism
#[derive(Copy, Debug, Clone)]
#[repr(C)]
#[cfg_attr(windows, repr(packed))]
pub struct PkcsOaepParams<'a> {
    /// mechanism ID of the message digest algorithm used to calculate the digest of the encoding
    /// parameter
    hash_alg: MechanismType,
    /// mask generation function to use on the encoded block
    mgf: PkcsMgfType,
    /// source of the encoding parameter
    source: CK_RSA_PKCS_OAEP_SOURCE_TYPE,
    /// data used as the input for the encoding parameter source
    source_data: *const c_void,
    /// length of the encoding parameter source input
    source_data_len: Ulong,
    /// marker type to ensure we don't outlive the source_data
    _marker: PhantomData<&'a [u8]>,
}

impl<'a> PkcsOaepParams<'a> {
    /// Construct a new `PkcsOaepParams`.
    ///
    /// # Arguments
    ///
    /// * `hash_alg` - The message digest algorithm used to calculate
    ///   a digest of the encoding parameter.
    /// * `mgf` - The mask generation function to use on the encoded block.
    /// * `encoding_parameter` - The encoding parameter, also known as the label.
    pub fn new(
        hash_alg: MechanismType,
        mgf: PkcsMgfType,
        encoding_parameter: PkcsOaepSource<'a>,
    ) -> Self {
        PkcsOaepParams {
            hash_alg,
            mgf,
            source: encoding_parameter.source_type(),
            source_data: encoding_parameter.source_ptr(),
            source_data_len: encoding_parameter.source_len(),
            _marker: PhantomData,
        }
    }

    /// Get the message digest algorithm for the `PkcsOaepParams`.
    pub fn hash_alg(&self) -> MechanismType {
        self.hash_alg
    }
}

impl<'a> From<PkcsOaepParams<'a>> for Mechanism<'a> {
    fn from(pkcs_oaep_params: PkcsOaepParams<'a>) -> Self {
        Mechanism::RsaPkcsOaep(pkcs_oaep_params)
    }
}
