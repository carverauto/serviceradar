// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Session management functions

use cryptoki_sys::{CKF_RW_SESSION, CKF_SERIAL_SESSION};

use crate::context::Pkcs11;
use crate::error::{Result, Rv};
use crate::session::Session;
use crate::slot::Slot;

use super::Function;

impl Pkcs11 {
    #[inline(always)]
    fn open_session(&self, slot_id: Slot, read_write: bool) -> Result<Session> {
        let mut session_handle = 0;

        let flags = if read_write {
            CKF_SERIAL_SESSION | CKF_RW_SESSION
        } else {
            CKF_SERIAL_SESSION
        };
        unsafe {
            Rv::from(get_pkcs11!(self, C_OpenSession)(
                slot_id.into(),
                flags,
                // TODO: abstract those types or create new functions for callbacks
                std::ptr::null_mut(),
                None,
                &mut session_handle,
            ))
            .into_result(Function::OpenSession)?;
        }

        Ok(Session::new(session_handle, self.clone()))
    }

    /// Open a new Read-Only session
    ///
    /// For a Read-Write session, use `open_rw_session`
    ///
    /// Note: No callback is set when opening the session.
    ///
    /// # Examples
    ///
    /// ```rust
    /// # fn main() -> testresult::TestResult {
    /// use cryptoki::session::Session;
    /// use cryptoki::context::Pkcs11;
    ///
    /// let mut client = Pkcs11::new(
    ///     std::env::var("TEST_PKCS11_MODULE")
    ///        .unwrap_or_else(|_| "/usr/local/lib/softhsm/libsofthsm2.so".to_string()),
    /// )?;
    /// client.initialize(cryptoki::context::CInitializeArgs::OsThreads)?;
    ///
    /// // Use the first slot
    /// let slot = client.get_all_slots()?[0];
    /// let session = client.open_ro_session(slot)?;
    /// # let _ = session; Ok(()) }
    /// ```
    pub fn open_ro_session(&self, slot_id: Slot) -> Result<Session> {
        self.open_session(slot_id, false)
    }

    /// Open a new Read/Write session
    ///
    /// Note: No callback is set when opening the session.
    pub fn open_rw_session(&self, slot_id: Slot) -> Result<Session> {
        self.open_session(slot_id, true)
    }
}
