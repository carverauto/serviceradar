// Copyright 2021 Contributors to the Parsec project.
// SPDX-License-Identifier: Apache-2.0
//! PKCS11 Slot info and associated flags

use crate::{string_from_blank_padded, types::Version};
use bitflags::bitflags;
use cryptoki_sys::*;
use std::fmt::Debug;

bitflags! {
    /// Collection of flags defined for [`CK_SLOT_INFO`]
    struct SlotInfoFlags: CK_FLAGS {
        const TOKEN_PRESENT=CKF_TOKEN_PRESENT;
        const REMOVABLE_DEVICE=CKF_REMOVABLE_DEVICE;
        const HW_SLOT = CKF_HW_SLOT;
    }
}

/// Information about a slot
#[derive(Debug, Clone)]
pub struct SlotInfo {
    slot_description: String,
    manufacturer_id: String,
    flags: SlotInfoFlags,
    hardware_version: Version,
    firmware_version: Version,
}

impl SlotInfo {
    /// String description of the slot
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This string is maximally 64 bytes (*not* chars) as UTF-8
    pub fn slot_description(&self) -> &str {
        &self.slot_description
    }

    /// ID of the slot manufacturer
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// This string is maximally 32 bytes (*not* chars) as UTF-8
    pub fn manufacturer_id(&self) -> &str {
        &self.manufacturer_id
    }

    /// True if a token is in the slot (e.g., a device is in the reader).
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// If this slot does not represent a removable device, a token is *always*
    /// considered to be present. That is, `slot.removable_device() == false`
    /// implies `slot.token_present() == true`.
    pub fn token_present(&self) -> bool {
        self.flags.contains(SlotInfoFlags::TOKEN_PRESENT)
    }

    /// True if the reader supports removable devices.
    ///
    /// **[Conformance](crate#conformance-notes):**
    /// For a given slot, this flag *never* changes
    pub fn removable_device(&self) -> bool {
        self.flags.contains(SlotInfoFlags::REMOVABLE_DEVICE)
    }

    /// True if the slot is a hardware slot, as opposed to a software slot
    /// implementing a "soft token"
    pub fn hardware_slot(&self) -> bool {
        self.flags.contains(SlotInfoFlags::HW_SLOT)
    }

    /// Version number of the slot's hardware
    pub fn hardware_version(&self) -> Version {
        self.hardware_version
    }

    /// Version number of the slot's firmware
    pub fn firmware_version(&self) -> Version {
        self.firmware_version
    }
}

#[doc(hidden)]
impl From<CK_SLOT_INFO> for SlotInfo {
    fn from(val: CK_SLOT_INFO) -> Self {
        Self {
            slot_description: string_from_blank_padded(&val.slotDescription),
            manufacturer_id: string_from_blank_padded(&val.manufacturerID),
            flags: SlotInfoFlags::from_bits_truncate(val.flags),
            hardware_version: val.hardwareVersion.into(),
            firmware_version: val.firmwareVersion.into(),
        }
    }
}

#[cfg(test)]
mod test {
    use super::{SlotInfo, SlotInfoFlags};
    use crate::types::Version;

    #[test]
    fn debug_flags_all() {
        let expected = "TOKEN_PRESENT | REMOVABLE_DEVICE | HW_SLOT";
        let all = SlotInfoFlags::all();
        let observed = format!("{all:#?}");
        assert_eq!(observed, expected);
    }

    #[test]
    fn debug_info() {
        let info = SlotInfo {
            slot_description: String::from("Slot Description"),
            manufacturer_id: String::from("Manufacturer ID"),
            flags: SlotInfoFlags::empty(),
            hardware_version: Version::new(0, 255),
            firmware_version: Version::new(255, 0),
        };
        let expected = r#"SlotInfo {
    slot_description: "Slot Description",
    manufacturer_id: "Manufacturer ID",
    flags: (empty),
    hardware_version: Version {
        major: 0,
        minor: 255,
    },
    firmware_version: Version {
        major: 255,
        minor: 0,
    },
}"#;
        let observed = format!("{info:#?}");
        assert_eq!(observed, expected);
    }
}
