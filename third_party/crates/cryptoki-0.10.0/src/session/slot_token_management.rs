// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Slot and token management functions

use crate::context::Function;
use crate::error::{Result, Rv};
use crate::session::Session;
use crate::types::AuthPin;
use secrecy::ExposeSecret;
use std::convert::TryInto;

impl Session {
    /// Initialize the normal user's pin for a token
    pub fn init_pin(&self, pin: &AuthPin) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_InitPIN)(
                self.handle(),
                pin.expose_secret().as_ptr() as *mut u8,
                pin.expose_secret().len().try_into()?,
            ))
            .into_result(Function::InitPIN)
        }
    }

    /// Changes the PIN of either the currently logged in user or of the `CKU_USER` if no user is
    /// logged in.
    pub fn set_pin(&self, old_pin: &AuthPin, new_pin: &AuthPin) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_SetPIN)(
                self.handle(),
                old_pin.expose_secret().as_ptr() as *mut u8,
                old_pin.expose_secret().len().try_into()?,
                new_pin.expose_secret().as_ptr() as *mut u8,
                new_pin.expose_secret().len().try_into()?,
            ))
            .into_result(Function::SetPIN)
        }
    }
}
