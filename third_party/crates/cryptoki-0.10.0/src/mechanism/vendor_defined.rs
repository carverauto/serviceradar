// Copyright 2024 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Mechanism types are defined with the objects and mechanism descriptions that use them.
//! Vendor defined values for this type may also be specified.
//! See: <https://docs.oasis-open.org/pkcs11/pkcs11-base/v3.0/os/pkcs11-base-v3.0-os.html#_Toc29976545>

use std::{marker::PhantomData, ptr::null_mut};

pub use cryptoki_sys::CKM_VENDOR_DEFINED;
use cryptoki_sys::CK_MECHANISM;

use super::{make_mechanism, MechanismType};

/// Vendor defined mechanism.
#[derive(Debug, Clone, Copy)]
pub struct VendorDefinedMechanism<'a> {
    pub(crate) inner: CK_MECHANISM,
    /// Marker type to ensure we don't outlive the data
    _marker: PhantomData<&'a [u8]>,
}

impl<'a> VendorDefinedMechanism<'a> {
    /// Create a new vendor defined mechanism.
    pub fn new<T>(mechanism_type: MechanismType, params: Option<&'a T>) -> Self {
        Self {
            inner: match params {
                Some(params) => make_mechanism(mechanism_type.val, params),
                None => CK_MECHANISM {
                    mechanism: mechanism_type.val,
                    pParameter: null_mut(),
                    ulParameterLen: 0,
                },
            },
            _marker: PhantomData,
        }
    }
}
