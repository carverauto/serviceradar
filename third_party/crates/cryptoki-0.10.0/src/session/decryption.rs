// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Decrypting data

use crate::context::Function;
use crate::error::{Result, Rv};
use crate::mechanism::Mechanism;
use crate::object::ObjectHandle;
use crate::session::Session;
use cryptoki_sys::*;
use std::convert::TryInto;

impl Session {
    /// Single-part decryption operation
    pub fn decrypt(
        &self,
        mechanism: &Mechanism,
        key: ObjectHandle,
        encrypted_data: &[u8],
    ) -> Result<Vec<u8>> {
        let mut mechanism: CK_MECHANISM = mechanism.into();
        let mut data_len = 0;

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptInit)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                key.handle(),
            ))
            .into_result(Function::DecryptInit)?;
        }

        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_Decrypt)(
                self.handle(),
                // C_Decrypt should not modify this buffer
                encrypted_data.as_ptr() as *mut u8,
                encrypted_data.len().try_into()?,
                std::ptr::null_mut(),
                &mut data_len,
            ))
            .into_result(Function::Decrypt)?;
        }

        let mut data = vec![0; data_len.try_into()?];

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_Decrypt)(
                self.handle(),
                encrypted_data.as_ptr() as *mut u8,
                encrypted_data.len().try_into()?,
                data.as_mut_ptr(),
                &mut data_len,
            ))
            .into_result(Function::Decrypt)?;
        }

        data.resize(data_len.try_into()?, 0);

        Ok(data)
    }

    /// Starts new multi-part decryption operation
    pub fn decrypt_init(&self, mechanism: &Mechanism, key: ObjectHandle) -> Result<()> {
        let mut mechanism: CK_MECHANISM = mechanism.into();

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptInit)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                key.handle(),
            ))
            .into_result(Function::DecryptInit)?;
        }

        Ok(())
    }

    /// Continues an ongoing multi-part decryption operation,
    /// taking in the next part of the encrypted data and returning its decryption
    pub fn decrypt_update(&self, encrypted_data: &[u8]) -> Result<Vec<u8>> {
        let mut data_len = 0;

        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptUpdate)(
                self.handle(),
                encrypted_data.as_ptr() as *mut u8,
                encrypted_data.len().try_into()?,
                std::ptr::null_mut(),
                &mut data_len,
            ))
            .into_result(Function::DecryptUpdate)?;
        }

        let mut data = vec![0; data_len.try_into()?];

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptUpdate)(
                self.handle(),
                encrypted_data.as_ptr() as *mut u8,
                encrypted_data.len().try_into()?,
                data.as_mut_ptr(),
                &mut data_len,
            ))
            .into_result(Function::DecryptUpdate)?;
        }

        Ok(data)
    }

    /// Finalizes ongoing multi-part decryption operation,
    /// returning any remaining bytes in the decrypted data
    pub fn decrypt_final(&self) -> Result<Vec<u8>> {
        let mut data_len = 0;

        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptFinal)(
                self.handle(),
                std::ptr::null_mut(),
                &mut data_len,
            ))
            .into_result(Function::DecryptFinal)?;
        }

        let mut data = vec![0; data_len.try_into()?];

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptFinal)(
                self.handle(),
                data.as_mut_ptr(),
                &mut data_len,
            ))
            .into_result(Function::DecryptFinal)?;
        }

        data.resize(data_len.try_into()?, 0);

        Ok(data)
    }
}
