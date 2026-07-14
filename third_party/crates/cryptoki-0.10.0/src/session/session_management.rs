// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Session management functions

use crate::context::Function;
use crate::error::{Result, Rv};
use crate::session::{Session, SessionInfo, UserType};
use crate::types::{AuthPin, RawAuthPin};

#[cfg(doc)]
use cryptoki_sys::CKF_PROTECTED_AUTHENTICATION_PATH;
use cryptoki_sys::CK_SESSION_INFO;
use log::error;
use secrecy::ExposeSecret;
use std::convert::{TryFrom, TryInto};

impl Drop for Session {
    fn drop(&mut self) {
        #[inline(always)]
        fn close(session: &Session) -> Result<()> {
            unsafe {
                Rv::from(get_pkcs11!(session.client(), C_CloseSession)(
                    session.handle(),
                ))
                .into_result(Function::CloseSession)
            }
        }

        if let Err(e) = close(self) {
            error!("Failed to close session: {}", e);
        }
    }
}

impl Session {
    /// Log a session in.
    ///
    /// # Arguments
    ///
    /// * `user_type` - The type of user to log in as
    /// * `pin` - The PIN to use, or `None` if you wish to use the protected authentication path
    ///
    /// _NOTE: By passing `None` into `login`, you must ensure that the
    /// [CKF_PROTECTED_AUTHENTICATION_PATH] flag is set in the `TokenFlags`._
    pub fn login(&self, user_type: UserType, pin: Option<&AuthPin>) -> Result<()> {
        let (pin, pin_len) = match pin {
            Some(pin) => (
                pin.expose_secret().as_ptr() as *mut u8,
                pin.expose_secret().len(),
            ),
            None => (std::ptr::null_mut(), 0),
        };
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_Login)(
                self.handle(),
                user_type.into(),
                pin,
                pin_len.try_into()?,
            ))
            .into_result(Function::Login)
        }
    }

    /// Logs a session in using a slice of raw bytes as a PIN. Some dongle drivers allow
    /// non UTF-8 characters in the PIN and as a result, we aren't guaranteed that we can
    /// pass in a UTF-8 string to login. Therefore, it's useful to be able to pass in raw bytes
    /// rather than convert a UTF-8 string to bytes.
    ///
    /// # Arguments
    ///
    /// * `user_type` - The type of user to log in as
    /// * `pin` - The PIN to use
    ///
    /// _NOTE: By passing `None` into `login`, you must ensure that the
    /// [CKF_PROTECTED_AUTHENTICATION_PATH] flag is set in the `TokenFlags`._
    pub fn login_with_raw(&self, user_type: UserType, pin: &RawAuthPin) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_Login)(
                self.handle(),
                user_type.into(),
                pin.expose_secret().as_ptr() as *mut u8,
                pin.expose_secret().len().try_into()?,
            ))
            .into_result(Function::Login)
        }
    }

    /// Log a session out
    pub fn logout(&self) -> Result<()> {
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_Logout)(self.handle()))
                .into_result(Function::Logout)
        }
    }

    /// Returns the information about a session
    pub fn get_session_info(&self) -> Result<SessionInfo> {
        let mut session_info = CK_SESSION_INFO::default();
        unsafe {
            Rv::from(get_pkcs11!(self.client(), C_GetSessionInfo)(
                self.handle(),
                &mut session_info,
            ))
            .into_result(Function::GetSessionInfo)?;
            SessionInfo::try_from(session_info)
        }
    }
}
