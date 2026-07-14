// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
// Depending on the target, CK_SLOT_ID is not u64
#![allow(clippy::useless_conversion)]

//! Slot and token types

mod slot_info;
mod token_info;

pub use slot_info::SlotInfo;
pub use token_info::{Limit, TokenInfo};

use crate::error::{Error, Result};
use cryptoki_sys::CK_SLOT_ID;
use std::convert::{TryFrom, TryInto};
use std::fmt::Formatter;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
/// Type identifying a slot
pub struct Slot {
    slot_id: CK_SLOT_ID,
}

impl std::fmt::LowerHex for Slot {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        let val = self.slot_id;

        std::fmt::LowerHex::fmt(&val, f)
    }
}

impl std::fmt::UpperHex for Slot {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        let val = self.slot_id;

        std::fmt::UpperHex::fmt(&val, f)
    }
}

impl Slot {
    pub(crate) fn new(slot_id: CK_SLOT_ID) -> Slot {
        Slot { slot_id }
    }

    /// Underlying ID used for a slot
    pub fn id(&self) -> u64 {
        self.slot_id.into()
    }
}

impl TryFrom<u64> for Slot {
    type Error = Error;

    fn try_from(slot_id: u64) -> Result<Self> {
        Ok(Self {
            slot_id: slot_id.try_into()?,
        })
    }
}

impl TryFrom<u32> for Slot {
    type Error = Error;

    fn try_from(slot_id: u32) -> Result<Self> {
        Ok(Self {
            slot_id: slot_id.into(),
        })
    }
}

impl From<Slot> for usize {
    fn from(slot: Slot) -> Self {
        slot.slot_id as usize
    }
}

impl From<Slot> for CK_SLOT_ID {
    fn from(slot: Slot) -> Self {
        slot.slot_id
    }
}

impl std::fmt::Display for Slot {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.slot_id)
    }
}
