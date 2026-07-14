// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Key management functions

use crate::context::Function;
use crate::error::{Result, Rv};
use crate::mechanism::Mechanism;
use crate::object::{Attribute, ObjectHandle};
use crate::session::Session;
use cryptoki_sys::{CK_ATTRIBUTE, CK_MECHANISM, CK_MECHANISM_PTR};
use std::convert::TryInto;

impl Session {
    /// Generate a secret key
    pub fn generate_key(
        &self,
        mechanism: &Mechanism,
        template: &[Attribute],
    ) -> Result<ObjectHandle> {
        let mut mechanism: CK_MECHANISM = mechanism.into();
        let mut template: Vec<CK_ATTRIBUTE> = template.iter().map(|attr| attr.into()).collect();
        let mut handle = 0;
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_GenerateKey)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                template.as_mut_ptr(),
                template.len().try_into()?,
                &mut handle,
            ))
            .into_result(Function::GenerateKey)?;
        }

        Ok(ObjectHandle::new(handle))
    }

    /// Generate a public/private key pair
    pub fn generate_key_pair(
        &self,
        mechanism: &Mechanism,
        pub_key_template: &[Attribute],
        priv_key_template: &[Attribute],
    ) -> Result<(ObjectHandle, ObjectHandle)> {
        let mut mechanism: CK_MECHANISM = mechanism.into();
        let mut pub_key_template: Vec<CK_ATTRIBUTE> =
            pub_key_template.iter().map(|attr| attr.into()).collect();
        let mut priv_key_template: Vec<CK_ATTRIBUTE> =
            priv_key_template.iter().map(|attr| attr.into()).collect();
        let mut pub_handle = 0;
        let mut priv_handle = 0;
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_GenerateKeyPair)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                pub_key_template.as_mut_ptr(),
                pub_key_template.len().try_into()?,
                priv_key_template.as_mut_ptr(),
                priv_key_template.len().try_into()?,
                &mut pub_handle,
                &mut priv_handle,
            ))
            .into_result(Function::GenerateKeyPair)?;
        }

        Ok((
            ObjectHandle::new(pub_handle),
            ObjectHandle::new(priv_handle),
        ))
    }

    /// Derives a key from a base key
    pub fn derive_key(
        &self,
        mechanism: &Mechanism,
        base_key: ObjectHandle,
        template: &[Attribute],
    ) -> Result<ObjectHandle> {
        let mut mechanism: CK_MECHANISM = mechanism.into();
        let mut template: Vec<CK_ATTRIBUTE> = template.iter().map(|attr| attr.into()).collect();
        let mut handle = 0;
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DeriveKey)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                base_key.handle(),
                template.as_mut_ptr(),
                template.len().try_into()?,
                &mut handle,
            ))
            .into_result(Function::DeriveKey)?;
        }

        Ok(ObjectHandle::new(handle))
    }

    /// Wrap key
    pub fn wrap_key(
        &self,
        mechanism: &Mechanism,
        wrapping_key: ObjectHandle,
        key: ObjectHandle,
    ) -> Result<Vec<u8>> {
        let mut mechanism: CK_MECHANISM = mechanism.into();
        unsafe {
            let mut wrapped_key_len = 0;

            Rv::from(get_pkcs11!(self.client(), C_WrapKey)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                wrapping_key.handle(),
                key.handle(),
                std::ptr::null_mut(),
                &mut wrapped_key_len,
            ))
            .into_result(Function::WrapKey)?;

            let mut wrapped_key = vec![0; wrapped_key_len.try_into()?];

            Rv::from(get_pkcs11!(self.client(), C_WrapKey)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                wrapping_key.handle(),
                key.handle(),
                wrapped_key.as_mut_ptr(),
                &mut wrapped_key_len,
            ))
            .into_result(Function::WrapKey)?;

            Ok(wrapped_key)
        }
    }

    /// Unwrap previously wrapped key
    pub fn unwrap_key(
        &self,
        mechanism: &Mechanism,
        unwrapping_key: ObjectHandle,
        wrapped_key: &[u8],
        template: &[Attribute],
    ) -> Result<ObjectHandle> {
        let mut mechanism: CK_MECHANISM = mechanism.into();
        let mut template: Vec<CK_ATTRIBUTE> = template.iter().map(|attr| attr.into()).collect();
        let mut handle = 0;
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_UnwrapKey)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                unwrapping_key.handle(),
                wrapped_key.as_ptr() as *mut u8,
                wrapped_key.len().try_into()?,
                template.as_mut_ptr(),
                template.len().try_into()?,
                &mut handle,
            ))
            .into_result(Function::UnwrapKey)?;
        }

        Ok(ObjectHandle::new(handle))
    }
}
