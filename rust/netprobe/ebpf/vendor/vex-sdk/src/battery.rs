//! V5 Smart Battery

use core::ffi::c_double;

unsafe extern "system" {
    pub fn vexBatteryVoltageGet() -> i32;
    pub fn vexBatteryCurrentGet() -> i32;
    pub fn vexBatteryTemperatureGet() -> c_double;
    pub fn vexBatteryCapacityGet() -> c_double;
}
