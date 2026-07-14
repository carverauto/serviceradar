// Copyright 2025 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Encrypting data

use crate::context::Function;
use crate::error::{Result, Rv};
use crate::mechanism::{Mechanism, MessageParam};
use crate::object::ObjectHandle;
use crate::session::Session;
use cryptoki_sys::*;
use std::convert::TryInto;

impl Session {
    /// Prepare a session for one or more Message-based decryption using the same mechanism and key
    pub fn message_decrypt_init(&self, mechanism: &Mechanism, key: ObjectHandle) -> Result<()> {
        let mut mechanism: CK_MECHANISM = mechanism.into();

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_MessageDecryptInit)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                key.handle(),
            ))
            .into_result(Function::MessageDecryptInit)?;
        }

        Ok(())
    }

    /// Decrypts a message in single part
    pub fn decrypt_message(
        &self,
        param: &MessageParam,
        aad: &[u8],
        encrypted_data: &[u8],
    ) -> Result<Vec<u8>> {
        let mut data_len = 0;
        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptMessage)(
                self.handle(),
                param.as_ptr(),
                param.len(),
                aad.as_ptr() as *mut u8,
                aad.len().try_into()?,
                encrypted_data.as_ptr() as *mut u8,
                encrypted_data.len().try_into()?,
                std::ptr::null_mut(),
                &mut data_len,
            ))
            .into_result(Function::DecryptMessage)?;
        }

        let mut data = vec![0; data_len.try_into()?];

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptMessage)(
                self.handle(),
                param.as_ptr(),
                param.len(),
                aad.as_ptr() as *mut u8,
                aad.len().try_into()?,
                encrypted_data.as_ptr() as *mut u8,
                encrypted_data.len().try_into()?,
                data.as_mut_ptr(),
                &mut data_len,
            ))
            .into_result(Function::DecryptMessage)?;
        }

        data.resize(data_len.try_into()?, 0);

        Ok(data)
    }

    /// Begin multi-part message decryption operation
    pub fn decrypt_message_begin(&self, param: MessageParam, aad: &[u8]) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptMessageBegin)(
                self.handle(),
                param.as_ptr(),
                param.len(),
                aad.as_ptr() as *mut u8,
                aad.len().try_into()?,
            ))
            .into_result(Function::DecryptMessageBegin)
        }
    }

    /// Continue mutli-part message decryption operation
    pub fn decrypt_message_next(
        &self,
        param: MessageParam,
        encrypted_data: &[u8],
        end: bool,
    ) -> Result<Vec<u8>> {
        let mut data_len = 0;
        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptMessageNext)(
                self.handle(),
                param.as_ptr(),
                param.len(),
                encrypted_data.as_ptr() as *mut u8,
                encrypted_data.len().try_into()?,
                std::ptr::null_mut(),
                &mut data_len,
                if end { CKF_END_OF_MESSAGE } else { 0 },
            ))
            .into_result(Function::DecryptMessageNext)?;
        }
        let mut data = vec![0; data_len.try_into()?];
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_DecryptMessageNext)(
                self.handle(),
                param.as_ptr(),
                param.len(),
                encrypted_data.as_ptr() as *mut u8,
                encrypted_data.len().try_into()?,
                data.as_mut_ptr(),
                &mut data_len,
                if end { CKF_END_OF_MESSAGE } else { 0 },
            ))
            .into_result(Function::DecryptMessageNext)?;
        }
        data.resize(data_len.try_into()?, 0);

        Ok(data)
    }

    /// Finishes Message-based decryption process
    pub fn message_decrypt_final(&self) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_MessageDecryptFinal)(
                self.handle(),
            ))
            .into_result(Function::MessageDecryptFinal)?;
        }

        Ok(())
    }
}
