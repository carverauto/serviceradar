//! V5 Optical Sensor

use core::ffi::c_double;

use crate::V5_DeviceT;

#[repr(C)]
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct V5_DeviceOpticalRaw {
    pub clear: u16,
    pub red: u16,
    pub green: u16,
    pub blue: u16,
}

#[repr(C)]
#[derive(Default, Debug, Copy, Clone, PartialEq)]
pub struct V5_DeviceOpticalRgb {
    pub red: c_double,
    pub green: c_double,
    pub blue: c_double,
    pub brightness: c_double,
}

#[repr(C)]
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct V5_DeviceOpticalGesture {
    pub udata: u8,
    pub ddata: u8,
    pub ldata: u8,
    pub rdata: u8,
    pub gesture_type: u8,
    pub padding: u8,
    pub count: u16,
    pub time: u32,
}

unsafe extern "system" {
    pub fn vexDeviceOpticalHueGet(device: V5_DeviceT) -> c_double;
    pub fn vexDeviceOpticalSatGet(device: V5_DeviceT) -> c_double;
    pub fn vexDeviceOpticalBrightnessGet(device: V5_DeviceT) -> c_double;
    pub fn vexDeviceOpticalProximityGet(device: V5_DeviceT) -> i32;
    pub fn vexDeviceOpticalRgbGet(device: V5_DeviceT, data: *mut V5_DeviceOpticalRgb);
    pub fn vexDeviceOpticalLedPwmSet(device: V5_DeviceT, value: i32);
    pub fn vexDeviceOpticalLedPwmGet(device: V5_DeviceT) -> i32;
    pub fn vexDeviceOpticalStatusGet(device: V5_DeviceT) -> u32;
    pub fn vexDeviceOpticalRawGet(device: V5_DeviceT, data: *mut V5_DeviceOpticalRaw);
    pub fn vexDeviceOpticalModeSet(device: V5_DeviceT, mode: u32);
    pub fn vexDeviceOpticalModeGet(device: V5_DeviceT) -> u32;
    pub fn vexDeviceOpticalGestureGet(
        device: V5_DeviceT,
        pData: *mut V5_DeviceOpticalGesture,
    ) -> u32;
    pub fn vexDeviceOpticalGestureEnable(device: V5_DeviceT);
    pub fn vexDeviceOpticalGestureDisable(device: V5_DeviceT);
    pub fn vexDeviceOpticalProximityThreshold(device: V5_DeviceT, value: i32);
    pub fn vexDeviceOpticalIntegrationTimeSet(device: V5_DeviceT, timeMs: c_double);
    pub fn vexDeviceOpticalIntegrationTimeGet(device: V5_DeviceT) -> c_double;
}
