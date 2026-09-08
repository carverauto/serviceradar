//! V5 Rotation Sensor

use crate::V5_DeviceT;

unsafe extern "system" {
    pub fn vexDeviceAbsEncReset(device: V5_DeviceT);
    pub fn vexDeviceAbsEncPositionSet(device: V5_DeviceT, position: i32);
    pub fn vexDeviceAbsEncPositionGet(device: V5_DeviceT) -> i32;
    pub fn vexDeviceAbsEncVelocityGet(device: V5_DeviceT) -> i32;
    pub fn vexDeviceAbsEncAngleGet(device: V5_DeviceT) -> i32;
    pub fn vexDeviceAbsEncReverseFlagSet(device: V5_DeviceT, value: bool);
    pub fn vexDeviceAbsEncReverseFlagGet(device: V5_DeviceT) -> bool;
    pub fn vexDeviceAbsEncStatusGet(device: V5_DeviceT) -> u32;
    pub fn vexDeviceAbsEncDataRateSet(device: V5_DeviceT, rate: u32);
}
