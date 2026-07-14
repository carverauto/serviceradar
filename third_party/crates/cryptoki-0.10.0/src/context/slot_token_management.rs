// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! Slot and token management functions

use crate::error::{Result, Rv};
use crate::label_from_str;
use crate::mechanism::{MechanismInfo, MechanismType};
use crate::slot::{Slot, SlotInfo, TokenInfo};
use crate::types::AuthPin;
use crate::{
    context::Pkcs11,
    error::{Error, RvError},
};
use cryptoki_sys::{
    CKF_DONT_BLOCK, CK_BBOOL, CK_FALSE, CK_FLAGS, CK_MECHANISM_INFO, CK_SLOT_ID, CK_SLOT_INFO,
    CK_TOKEN_INFO, CK_TRUE,
};
use secrecy::ExposeSecret;
use std::convert::{TryFrom, TryInto};

use crate::error::RvError::BufferTooSmall;

use super::Function;

impl Pkcs11 {
    #[inline(always)]
    fn get_slots(&self, with_token: CK_BBOOL) -> Result<Vec<Slot>> {
        let mut slot_count = 0;
        let rval = unsafe {
            get_pkcs11!(self, C_GetSlotList)(with_token, std::ptr::null_mut(), &mut slot_count)
        };
        Rv::from(rval).into_result(Function::GetSlotList)?;

        let mut slots;
        loop {
            slots = vec![0; slot_count as usize];
            let rval = unsafe {
                get_pkcs11!(self, C_GetSlotList)(with_token, slots.as_mut_ptr(), &mut slot_count)
            };
            // Account for a race condition between the call to get the
            // slot_count and the last call in which the number of slots grew.
            // In this case, slot_count will have been updated to the larger amount
            // and we want to loop again with a resized buffer.
            if !matches!(Rv::from(rval), Rv::Error(BufferTooSmall)) {
                // Account for other possible error types
                Rv::from(rval).into_result(Function::GetSlotList)?;
                // Otherwise, we have a valid list to process
                break;
            }
        }
        // Account for the same race condition, but with a shrinking slot_count
        slots.truncate(slot_count as usize);
        Ok(slots.into_iter().map(Slot::new).collect())
    }

    /// Get all slots available with a token
    pub fn get_slots_with_token(&self) -> Result<Vec<Slot>> {
        self.get_slots(CK_TRUE)
    }

    /// Get all slots
    pub fn get_all_slots(&self) -> Result<Vec<Slot>> {
        self.get_slots(CK_FALSE)
    }

    /// Get all slots available with a token
    pub fn get_slots_with_initialized_token(&self) -> Result<Vec<Slot>> {
        let slots = self.get_slots_with_token()?;

        slots
            .into_iter()
            .filter_map(|slot| match self.get_token_info(slot) {
                Ok(token_info) => {
                    if token_info.token_initialized() {
                        Some(Ok(slot))
                    } else {
                        None
                    }
                }
                Err(e) => Some(Err(e)),
            })
            .collect()
    }

    /// Initialize a token
    ///
    /// Currently will use an empty label for all tokens.
    pub fn init_token(&self, slot: Slot, pin: &AuthPin, label: &str) -> Result<()> {
        let label = label_from_str(label);
        unsafe {
            Rv::from(get_pkcs11!(self, C_InitToken)(
                slot.into(),
                pin.expose_secret().as_ptr() as *mut u8,
                pin.expose_secret().len().try_into()?,
                label.as_ptr() as *mut u8,
            ))
            .into_result(Function::InitToken)
        }
    }

    /// Returns the slot info
    pub fn get_slot_info(&self, slot: Slot) -> Result<SlotInfo> {
        unsafe {
            let mut slot_info = CK_SLOT_INFO::default();
            Rv::from(get_pkcs11!(self, C_GetSlotInfo)(
                slot.into(),
                &mut slot_info,
            ))
            .into_result(Function::GetSlotInfo)?;
            Ok(SlotInfo::from(slot_info))
        }
    }

    /// Returns information about a specific token
    pub fn get_token_info(&self, slot: Slot) -> Result<TokenInfo> {
        unsafe {
            let mut token_info = CK_TOKEN_INFO::default();
            Rv::from(get_pkcs11!(self, C_GetTokenInfo)(
                slot.into(),
                &mut token_info,
            ))
            .into_result(Function::GetTokenInfo)?;
            TokenInfo::try_from(token_info)
        }
    }

    /// Get all mechanisms support by a slot
    pub fn get_mechanism_list(&self, slot: Slot) -> Result<Vec<MechanismType>> {
        let mut mechanism_count = 0;

        unsafe {
            Rv::from(get_pkcs11!(self, C_GetMechanismList)(
                slot.into(),
                std::ptr::null_mut(),
                &mut mechanism_count,
            ))
            .into_result(Function::GetMechanismList)?;
        }

        let mut mechanisms = vec![0; mechanism_count.try_into()?];

        unsafe {
            Rv::from(get_pkcs11!(self, C_GetMechanismList)(
                slot.into(),
                mechanisms.as_mut_ptr(),
                &mut mechanism_count,
            ))
            .into_result(Function::GetMechanismList)?;
        }

        // Truncate mechanisms if count decreased.
        mechanisms.truncate(mechanism_count.try_into()?);

        Ok(mechanisms
            .into_iter()
            .filter_map(|type_| type_.try_into().ok())
            .collect())
    }

    /// Get detailed information about a mechanism for a slot
    pub fn get_mechanism_info(&self, slot: Slot, type_: MechanismType) -> Result<MechanismInfo> {
        unsafe {
            let mut mechanism_info = CK_MECHANISM_INFO::default();
            Rv::from(get_pkcs11!(self, C_GetMechanismInfo)(
                slot.into(),
                type_.into(),
                &mut mechanism_info,
            ))
            .into_result(Function::GetMechanismInfo)?;
            Ok(MechanismInfo::from(mechanism_info))
        }
    }

    fn wait_for_slot_event_impl(&self, flags: CK_FLAGS) -> Result<Slot> {
        unsafe {
            let mut slot: CK_SLOT_ID = 0;
            let wait_for_slot_event = get_pkcs11!(self, C_WaitForSlotEvent);
            let rv = wait_for_slot_event(flags, &mut slot, std::ptr::null_mut());
            Rv::from(rv).into_result(Function::WaitForSlotEvent)?;
            Ok(Slot::new(slot))
        }
    }

    /// Wait for slot events (insertion or removal of a token)
    pub fn wait_for_slot_event(&self) -> Result<Slot> {
        self.wait_for_slot_event_impl(0)
    }

    /// Get the latest slot event (insertion or removal of a token)
    pub fn get_slot_event(&self) -> Result<Option<Slot>> {
        match self.wait_for_slot_event_impl(CKF_DONT_BLOCK) {
            Err(Error::Pkcs11(RvError::NoEvent, Function::WaitForSlotEvent)) => Ok(None),
            Ok(slot) => Ok(Some(slot)),
            Err(x) => Err(x),
        }
    }
}
