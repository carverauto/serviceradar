//! V5 GPS

use core::ffi::c_double;

use crate::V5_DeviceT;

#[repr(C, packed)]
#[derive(Default, Debug, Copy, Clone, PartialEq)]
pub struct V5_DeviceGpsRaw {
    pub x: c_double,
    pub y: c_double,
    pub z: c_double,
    pub w: c_double,
}

#[repr(C, packed)]
#[derive(Default, Debug, Copy, Clone, PartialEq)]
pub struct V5_DeviceGpsAttitude {
    pub pitch: c_double, // x
    pub roll: c_double,  // y
    pub yaw: c_double,   // z

    // spacial position on the field
    pub position_x: c_double,
    pub position_y: c_double,
    pub position_z: c_double,

    // alternative roll, pitch and yaw
    pub az: c_double,
    pub el: c_double,
    pub rot: c_double,
}

#[repr(C, packed)]
#[derive(Default, Debug, Copy, Clone, PartialEq)]
pub struct V5_DeviceGpsQuaternion {
    pub x: c_double,
    pub y: c_double,
    pub z: c_double,
    pub w: c_double,
}

unsafe extern "system" {
    pub fn vexDeviceGpsReset(device: V5_DeviceT);
    pub fn vexDeviceGpsHeadingGet(device: V5_DeviceT) -> c_double;
    pub fn vexDeviceGpsDegreesGet(device: V5_DeviceT) -> c_double;
    pub fn vexDeviceGpsQuaternionGet(device: V5_DeviceT, data: *mut V5_DeviceGpsQuaternion);
    pub fn vexDeviceGpsAttitudeGet(device: V5_DeviceT, data: *mut V5_DeviceGpsAttitude, bRaw: bool);
    pub fn vexDeviceGpsRawGyroGet(device: V5_DeviceT, data: *mut V5_DeviceGpsRaw);
    pub fn vexDeviceGpsRawAccelGet(device: V5_DeviceT, data: *mut V5_DeviceGpsRaw);
    pub fn vexDeviceGpsStatusGet(device: V5_DeviceT) -> u32;
    pub fn vexDeviceGpsModeSet(device: V5_DeviceT, mode: u32);
    pub fn vexDeviceGpsModeGet(device: V5_DeviceT) -> u32;
    pub fn vexDeviceGpsDataRateSet(device: V5_DeviceT, rate: u32);
    pub fn vexDeviceGpsOriginSet(device: V5_DeviceT, ox: c_double, oy: c_double);
    pub fn vexDeviceGpsOriginGet(device: V5_DeviceT, ox: *mut c_double, oy: *mut c_double);
    pub fn vexDeviceGpsRotationSet(device: V5_DeviceT, value: c_double);
    pub fn vexDeviceGpsRotationGet(device: V5_DeviceT) -> c_double;
    pub fn vexDeviceGpsInitialPositionSet(
        device: V5_DeviceT,
        initial_x: c_double,
        initial_y: c_double,
        initial_rotation: c_double,
    );
    pub fn vexDeviceGpsErrorGet(device: V5_DeviceT) -> c_double;
}
