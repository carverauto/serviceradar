//! Rangefinder/Lidar Sensor
//!
//! This sensor is not sold by VEX.

use crate::V5_DeviceT;

unsafe extern "system" {
    pub fn vexDeviceRangeValueGet(device: V5_DeviceT) -> i32;
}
