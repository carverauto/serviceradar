//! V5 Distance Sensor

use core::ffi::c_double;

use crate::V5_DeviceT;

unsafe extern "system" {
    pub fn vexDeviceDistanceDistanceGet(device: V5_DeviceT) -> u32;
    pub fn vexDeviceDistanceConfidenceGet(device: V5_DeviceT) -> u32;
    pub fn vexDeviceDistanceStatusGet(device: V5_DeviceT) -> u32;
    pub fn vexDeviceDistanceObjectSizeGet(device: V5_DeviceT) -> i32;
    pub fn vexDeviceDistanceObjectVelocityGet(device: V5_DeviceT) -> c_double;
}
