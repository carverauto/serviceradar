//! V5 AI Vision Sensor

use core::ffi::{c_double, c_float};

use crate::V5_DeviceT;

#[repr(C, packed)]
#[derive(Default, Debug, Copy, Clone, PartialEq)]
pub struct V5_DeviceAiVisionColor {
    pub id: u8,
    pub red: u8,
    pub grn: u8,
    pub blu: u8,
    pub hangle: c_float,
    pub hdsat: c_float,
    pub reserved: u32,
}

#[repr(C, packed)]
#[derive(Copy, Clone)]
pub struct V5_DeviceAiVisionObject {
    pub id: u8,
    pub r#type: u8,
    pub object: V5_DeviceAiVisionObjectData,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub union V5_DeviceAiVisionObjectData {
    pub color: V5_DeviceAiVisionColorData,
    pub tag: V5_DeviceAiVisionTagData,
    pub model: V5_DeviceAiVisionModelData,
}

/// Color Detection Data
#[repr(C)]
#[derive(Default, Debug, Copy, Clone, PartialEq)]
pub struct V5_DeviceAiVisionColorData {
    /// left side of object
    pub xoffset: u16,
    /// top of object
    pub yoffset: u16,
    /// width of object
    pub width: u16,
    /// height of object
    pub height: u16,
    /// angle of CC object in 0.1 deg units
    pub angle: u16,
}

/// Apriltag coordinate data
#[repr(C)]
#[derive(Default, Debug, Copy, Clone, PartialEq)]
pub struct V5_DeviceAiVisionTagData {
    pub x0: i16,
    pub y0: i16,
    pub x1: i16,
    pub y1: i16,
    pub x2: i16,
    pub y2: i16,
    pub x3: i16,
    pub y3: i16,
}

/// AI Model Data
#[repr(C)]
#[derive(Default, Debug, Copy, Clone, PartialEq)]
pub struct V5_DeviceAiVisionModelData {
    /// left side of object
    pub xoffset: u16,
    /// top of object
    pub yoffset: u16,
    /// width of object
    pub width: u16,
    /// height of object
    pub height: u16,
    /// confidence score
    pub score: u16,
}

#[repr(C, packed)]
#[derive(Default, Debug, Copy, Clone, PartialEq)]
pub struct V5_DeviceAiVisionCode {
    pub id: u8,
    pub len: u8,
    pub c1: i16,
    pub c2: i16,
    pub c3: i16,
    pub c4: i16,
    pub c5: i16,
    pub c6: i16,
    pub c7: i16,
}

unsafe extern "system" {
    pub fn vexDeviceAiVisionClassNameGet(device: V5_DeviceT, id: i32, pName: *mut u8) -> i32;
    pub fn vexDeviceAiVisionCodeGet(
        device: V5_DeviceT,
        id: u32,
        pCode: *mut V5_DeviceAiVisionCode,
    ) -> bool;
    pub fn vexDeviceAiVisionCodeSet(device: V5_DeviceT, pCode: *mut V5_DeviceAiVisionCode);
    pub fn vexDeviceAiVisionColorGet(
        device: V5_DeviceT,
        id: u32,
        pColor: *mut V5_DeviceAiVisionColor,
    ) -> bool;
    pub fn vexDeviceAiVisionColorSet(device: V5_DeviceT, pColor: *mut V5_DeviceAiVisionColor);
    pub fn vexDeviceAiVisionModeGet(device: V5_DeviceT) -> u32;
    pub fn vexDeviceAiVisionModeSet(device: V5_DeviceT, mode: u32);
    pub fn vexDeviceAiVisionObjectCountGet(device: V5_DeviceT) -> i32;
    pub fn vexDeviceAiVisionObjectGet(
        device: V5_DeviceT,
        indexObj: u32,
        pObject: *mut V5_DeviceAiVisionObject,
    ) -> i32;
    pub fn vexDeviceAiVisionSensorSet(device: V5_DeviceT, brightness: c_double, contrast: c_double);
    pub fn vexDeviceAiVisionStatusGet(device: V5_DeviceT) -> u32;
    pub fn vexDeviceAiVisionTemperatureGet(device: V5_DeviceT) -> c_double;
}
