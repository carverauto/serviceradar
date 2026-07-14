// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Signing and authentication functions

use crate::context::Function;
use crate::error::{Result, Rv};
use crate::mechanism::Mechanism;
use crate::object::ObjectHandle;
use crate::session::Session;
use cryptoki_sys::*;
use std::convert::TryInto;

impl Session {
    /// Sign data in single-part
    pub fn sign(&self, mechanism: &Mechanism, key: ObjectHandle, data: &[u8]) -> Result<Vec<u8>> {
        let mut mechanism: CK_MECHANISM = mechanism.into();
        let mut signature_len = 0;

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_SignInit)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                key.handle(),
            ))
            .into_result(Function::SignInit)?;
        }

        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_Sign)(
                self.handle(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                std::ptr::null_mut(),
                &mut signature_len,
            ))
            .into_result(Function::Sign)?;
        }

        let mut signature = vec![0; signature_len.try_into()?];

        //TODO: we should add a new error instead of those unwrap!
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_Sign)(
                self.handle(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                signature.as_mut_ptr(),
                &mut signature_len,
            ))
            .into_result(Function::Sign)?;
        }

        signature.resize(signature_len.try_into()?, 0);

        Ok(signature)
    }

    /// Starts new multi-part signing operation
    pub fn sign_init(&self, mechanism: &Mechanism, key: ObjectHandle) -> Result<()> {
        let mut mechanism: CK_MECHANISM = mechanism.into();

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_SignInit)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                key.handle(),
            ))
            .into_result(Function::SignInit)?;
        }

        Ok(())
    }

    /// Continues an ongoing multi-part signing operation,
    /// taking in the next part of the data to sign
    pub fn sign_update(&self, data: &[u8]) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_SignUpdate)(
                self.handle(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
            ))
            .into_result(Function::SignUpdate)?;
        }

        Ok(())
    }

    /// Finalizes ongoing multi-part signing operation,
    /// returning the signature
    pub fn sign_final(&self) -> Result<Vec<u8>> {
        let mut signature_len = 0;

        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_SignFinal)(
                self.handle(),
                std::ptr::null_mut(),
                &mut signature_len,
            ))
            .into_result(Function::SignFinal)?;
        }

        let mut signature = vec![0; signature_len.try_into()?];

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_SignFinal)(
                self.handle(),
                signature.as_mut_ptr(),
                &mut signature_len,
            ))
            .into_result(Function::SignFinal)?;
        }

        signature.resize(signature_len.try_into()?, 0);

        Ok(signature)
    }

    /// Verify data in single-part
    pub fn verify(
        &self,
        mechanism: &Mechanism,
        key: ObjectHandle,
        data: &[u8],
        signature: &[u8],
    ) -> Result<()> {
        let mut mechanism: CK_MECHANISM = mechanism.into();

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_VerifyInit)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                key.handle(),
            ))
            .into_result(Function::VerifyInit)?;
        }

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_Verify)(
                self.handle(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                signature.as_ptr() as *mut u8,
                signature.len().try_into()?,
            ))
            .into_result(Function::Verify)
        }
    }

    /// Starts new multi-part verifying operation
    pub fn verify_init(&self, mechanism: &Mechanism, key: ObjectHandle) -> Result<()> {
        let mut mechanism: CK_MECHANISM = mechanism.into();

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_VerifyInit)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                key.handle(),
            ))
            .into_result(Function::VerifyInit)?;
        }

        Ok(())
    }

    /// Continues an ongoing multi-part verifying operation,
    /// taking in the next part of the data to verify
    pub fn verify_update(&self, data: &[u8]) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_VerifyUpdate)(
                self.handle(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
            ))
            .into_result(Function::VerifyUpdate)?;
        }

        Ok(())
    }

    /// Finalizes ongoing multi-part verifying operation,
    /// returning Ok only if the signature verifies
    pub fn verify_final(&self, signature: &[u8]) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_VerifyFinal)(
                self.handle(),
                signature.as_ptr() as *mut u8,
                signature.len().try_into()?,
            ))
            .into_result(Function::VerifyFinal)?;
        }

        Ok(())
    }
}
