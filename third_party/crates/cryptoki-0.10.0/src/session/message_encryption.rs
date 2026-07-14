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
    /// Prepare a session for one or more Message-based encryption using the same mechanism and key
    pub fn message_encrypt_init(&self, mechanism: &Mechanism, key: ObjectHandle) -> Result<()> {
        let mut mechanism: CK_MECHANISM = mechanism.into();

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_MessageEncryptInit)(
                self.handle(),
                &mut mechanism as CK_MECHANISM_PTR,
                key.handle(),
            ))
            .into_result(Function::MessageEncryptInit)?;
        }

        Ok(())
    }

    /// Encrypts a message in single part
    pub fn encrypt_message(
        &self,
        param: &MessageParam,
        aad: &[u8],
        data: &[u8],
    ) -> Result<Vec<u8>> {
        let mut encrypted_data_len = 0;
        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptMessage)(
                self.handle(),
                param.as_ptr(),
                param.len(),
                aad.as_ptr() as *mut u8,
                aad.len().try_into()?,
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                std::ptr::null_mut(),
                &mut encrypted_data_len,
            ))
            .into_result(Function::EncryptMessage)?;
        }

        let mut encrypted_data = vec![0; encrypted_data_len.try_into()?];

        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptMessage)(
                self.handle(),
                param.as_ptr(),
                param.len(),
                aad.as_ptr() as *mut u8,
                aad.len().try_into()?,
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                encrypted_data.as_mut_ptr(),
                &mut encrypted_data_len,
            ))
            .into_result(Function::EncryptMessage)?;
        }

        encrypted_data.resize(encrypted_data_len.try_into()?, 0);

        Ok(encrypted_data)
    }

    /// Begin multi-part message encryption operation
    pub fn encrypt_message_begin(&self, param: MessageParam, aad: &[u8]) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptMessageBegin)(
                self.handle(),
                param.as_ptr(),
                param.len(),
                aad.as_ptr() as *mut u8,
                aad.len().try_into()?,
            ))
            .into_result(Function::EncryptMessageBegin)
        }
    }

    /// Continue mutli-part message encryption operation
    pub fn encrypt_message_next(
        &self,
        param: MessageParam,
        data: &[u8],
        end: bool,
    ) -> Result<Vec<u8>> {
        let mut encrypted_data_len = 0;
        // Get the output buffer length
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptMessageNext)(
                self.handle(),
                param.as_ptr(),
                param.len(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                std::ptr::null_mut(),
                &mut encrypted_data_len,
                if end { CKF_END_OF_MESSAGE } else { 0 },
            ))
            .into_result(Function::EncryptMessageNext)?;
        }
        let mut encrypted_data = vec![0; encrypted_data_len.try_into()?];
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_EncryptMessageNext)(
                self.handle(),
                param.as_ptr(),
                param.len(),
                data.as_ptr() as *mut u8,
                data.len().try_into()?,
                encrypted_data.as_mut_ptr(),
                &mut encrypted_data_len,
                if end { CKF_END_OF_MESSAGE } else { 0 },
            ))
            .into_result(Function::EncryptMessageNext)?;
        }
        encrypted_data.resize(encrypted_data_len.try_into()?, 0);

        Ok(encrypted_data)
    }

    /// Finishes Message-based encryption process
    pub fn message_encrypt_final(&self) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_MessageEncryptFinal)(
                self.handle(),
            ))
            .into_result(Function::MessageEncryptFinal)?;
        }

        Ok(())
    }
}
