//! V5 Workcell Electromagnet

use core::ffi::c_double;

use crate::V5_DeviceT;

#[repr(transparent)]
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct V5_DeviceMagnetDuration(pub core::ffi::c_uchar);

impl V5_DeviceMagnetDuration {
    pub const kMagnetDurationShort: Self = Self(0);
    pub const kMagnetDurationMedium: Self = Self(1);
    pub const kMagnetDurationLong: Self = Self(2);
    pub const kMagnetDurationExtraLong: Self = Self(3);
}

unsafe extern "system" {
    pub fn vexDeviceMagnetPowerSet(device: V5_DeviceT, value: i32, time: i32);
    pub fn vexDeviceMagnetPowerGet(device: V5_DeviceT) -> i32;
    pub fn vexDeviceMagnetPickup(device: V5_DeviceT, duration: V5_DeviceMagnetDuration);
    pub fn vexDeviceMagnetDrop(device: V5_DeviceT, duration: V5_DeviceMagnetDuration);
    pub fn vexDeviceMagnetTemperatureGet(device: V5_DeviceT) -> c_double;
    pub fn vexDeviceMagnetCurrentGet(device: V5_DeviceT) -> c_double;
    pub fn vexDeviceMagnetStatusGet(device: V5_DeviceT) -> u32;
}
