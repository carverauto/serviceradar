// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Encrypting data

use crate::context::Function;
use crate::error::{Result, Rv};
use crate::mechanism::Mechanism;
use crate::object::ObjectHandle;
use crate::session::Session;
use cryptoki_sys::*;
use std::convert::TryInto;

impl Session {
    /// Single-part encryption operation
    pub fn encrypt(
        &self,
        mechanism: &Mechanism,
        key: ObjectHandle,
        data: &[u8],
    ) -> Result<Vec<u8>> {
        let mut mechanism: CK_MECHANISM = mechanism.into();
        let mut encrypted_data_len = 0;

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptInit)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                key.handle(),
            ))
            .into_result(Function::EncryptInit)?;
        }

        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_Encrypt)(
                self.handle(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                std::ptr::null_mut(),
                &mut encrypted_data_len,
            ))
            .into_result(Function::Encrypt)?;
        }

        let mut encrypted_data = vec![0; encrypted_data_len.try_into()?];

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_Encrypt)(
                self.handle(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                encrypted_data.as_mut_ptr(),
                &mut encrypted_data_len,
            ))
            .into_result(Function::Encrypt)?;
        }

        encrypted_data.resize(encrypted_data_len.try_into()?, 0);

        Ok(encrypted_data)
    }

    /// Starts new multi-part encryption operation
    pub fn encrypt_init(&self, mechanism: &Mechanism, key: ObjectHandle) -> Result<()> {
        let mut mechanism: CK_MECHANISM = mechanism.into();

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptInit)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                key.handle(),
            ))
            .into_result(Function::EncryptInit)?;
        }

        Ok(())
    }

    /// Continues an ongoing multi-part encryption operation,
    /// taking in the next part of the data and returning its encryption
    pub fn encrypt_update(&self, data: &[u8]) -> Result<Vec<u8>> {
        let mut encrypted_data_len = 0;

        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptUpdate)(
                self.handle(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                std::ptr::null_mut(),
                &mut encrypted_data_len,
            ))
            .into_result(Function::EncryptUpdate)?;
        }

        let mut encrypted_data = vec![0; encrypted_data_len.try_into()?];

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptUpdate)(
                self.handle(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                encrypted_data.as_mut_ptr(),
                &mut encrypted_data_len,
            ))
            .into_result(Function::EncryptUpdate)?;
        }

        Ok(encrypted_data)
    }

    /// Finalizes ongoing multi-part encryption operation,
    /// returning any remaining bytes in the encrypted data
    pub fn encrypt_final(&self) -> Result<Vec<u8>> {
        let mut encrypted_data_len = 0;

        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptFinal)(
                self.handle(),
                std::ptr::null_mut(),
                &mut encrypted_data_len,
            ))
            .into_result(Function::EncryptFinal)?;
        }

        let mut encrypted_data = vec![0; encrypted_data_len.try_into()?];

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptFinal)(
                self.handle(),
                encrypted_data.as_mut_ptr(),
                &mut encrypted_data_len,
            ))
            .into_result(Function::EncryptFinal)?;
        }

        encrypted_data.resize(encrypted_data_len.try_into()?, 0);

        Ok(encrypted_data)
    }
}
