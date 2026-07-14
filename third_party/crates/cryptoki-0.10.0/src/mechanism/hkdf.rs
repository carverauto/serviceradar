// Copyright 2024 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Mechanisms of hash-based key derive function (HKDF)
//! See: <https://docs.oasis-open.org/pkcs11/pkcs11-curr/v3.0/os/pkcs11-curr-v3.0-os.html#_Toc30061597>

use std::{convert::TryInto, marker::PhantomData, ptr::null_mut, slice};

use cryptoki_sys::{CKF_HKDF_SALT_DATA, CKF_HKDF_SALT_KEY, CKF_HKDF_SALT_NULL};

use crate::object::ObjectHandle;

use super::MechanismType;

/// The salt for the extract stage.
#[derive(Debug, Clone, Copy)]
pub enum HkdfSalt<'a> {
    /// CKF_HKDF_SALT_NULL no salt is supplied.
    Null,
    /// CKF_HKDF_SALT_DATA salt is supplied as a data in pSalt with length ulSaltLen.
    Data(&'a [u8]),
    /// CKF_HKDF_SALT_KEY salt is supplied as a key in hSaltKey
    Key(ObjectHandle),
}

/// HKDF parameters.
///
/// This structure wraps a `CK_HKDF_PARAMS` structure.
#[derive(Debug, Clone, Copy)]
#[repr(transparent)]
pub struct HkdfParams<'a> {
    inner: cryptoki_sys::CK_HKDF_PARAMS,
    /// Marker type to ensure we don't outlive the data
    _marker: PhantomData<&'a [u8]>,
}

impl<'a> HkdfParams<'a> {
    /// Construct parameters for hash-based key derive function (HKDF).
    ///
    /// # Arguments
    ///
    /// * `prf_hash_mechanism` - The base hash used for the HMAC in the underlying HKDF operation
    ///
    /// * `salt` - The salt for the extract stage, skip extract if `None`.
    ///
    /// * `info` - The info string for the expand stage, skip expand if `None`.
    pub fn new(
        prf_hash_mechanism: MechanismType,
        salt: Option<HkdfSalt>,
        info: Option<&'a [u8]>,
    ) -> Self {
        Self {
            inner: cryptoki_sys::CK_HKDF_PARAMS {
                bExtract: salt.is_some() as u8,
                bExpand: info.is_some() as u8,
                prfHashMechanism: *prf_hash_mechanism,
                ulSaltType: match salt {
                    None | Some(HkdfSalt::Null) => CKF_HKDF_SALT_NULL,
                    Some(HkdfSalt::Data(_)) => CKF_HKDF_SALT_DATA,
                    Some(HkdfSalt::Key(_)) => CKF_HKDF_SALT_KEY,
                },
                pSalt: if let Some(HkdfSalt::Data(data)) = salt {
                    data.as_ptr() as *mut _
                } else {
                    null_mut()
                },
                ulSaltLen: if let Some(HkdfSalt::Data(data)) = salt {
                    data.len()
                        .try_into()
                        .expect("salt length does not fit in CK_ULONG")
                } else {
                    0
                },
                hSaltKey: if let Some(HkdfSalt::Key(key)) = salt {
                    key.handle()
                } else {
                    0
                },
                pInfo: if let Some(info) = info {
                    info.as_ptr() as *mut _
                } else {
                    null_mut()
                },
                ulInfoLen: if let Some(info) = info {
                    info.len()
                        .try_into()
                        .expect("salt length does not fit in CK_ULONG")
                } else {
                    0
                },
            },
            _marker: PhantomData,
        }
    }

    /// Whether to execute the extract portion of HKDF.
    pub fn extract(&self) -> bool {
        self.inner.bExtract != 0
    }

    /// Whether to execute the expand portion of HKDF.
    pub fn expand(&self) -> bool {
        self.inner.bExpand != 0
    }

    /// The salt for the extract stage.
    pub fn salt(&self) -> HkdfSalt<'a> {
        match self.inner.ulSaltType {
            CKF_HKDF_SALT_NULL => HkdfSalt::Null,
            CKF_HKDF_SALT_DATA => HkdfSalt::Data(unsafe {
                slice::from_raw_parts(self.inner.pSalt, self.inner.ulSaltLen as _)
            }),
            CKF_HKDF_SALT_KEY => HkdfSalt::Key(ObjectHandle::new(self.inner.hSaltKey)),
            _ => unreachable!(),
        }
    }

    /// The info string for the expand stage.
    pub fn info(&self) -> &'a [u8] {
        unsafe { slice::from_raw_parts(self.inner.pInfo, self.inner.ulInfoLen as _) }
    }
}
