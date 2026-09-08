//! V5 LED
//!
//! This device is not sold by VEX and only exists as development hardware.

use crate::V5_DeviceT;

#[repr(transparent)]
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct V5_DeviceLedColor(pub core::ffi::c_uint);

impl V5_DeviceLedColor {
    pub const kLedColorBlack: Self = Self(0);
    pub const kLedColorRed: Self = Self(0xFF0000);
    pub const kLedColorGreen: Self = Self(0x00FF00);
    pub const kLedColorBlue: Self = Self(0x0000FF);
    pub const kLedColorYellow: Self = Self(0xFFFF00);
    pub const kLedColorCyan: Self = Self(0x00FFFF);
    pub const kLedColorMagenta: Self = Self(0xFF00FF);
    pub const kLedColorWhite: Self = Self(0xFFFFFF);
}

unsafe extern "system" {
    pub fn vexDeviceLedSet(device: V5_DeviceT, value: V5_DeviceLedColor);
    pub fn vexDeviceLedRgbSet(device: V5_DeviceT, color: u32);
    pub fn vexDeviceLedGet(device: V5_DeviceT) -> V5_DeviceLedColor;
    pub fn vexDeviceLedRgbGet(device: V5_DeviceT) -> u32;
}
