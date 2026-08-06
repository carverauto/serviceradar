//! ADI Devices

use core::ffi::c_double;

use crate::V5_DeviceT;

#[repr(transparent)]
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct V5_AdiPortConfiguration(pub core::ffi::c_uchar);

impl V5_AdiPortConfiguration {
    pub const kAdiPortTypeAnalogIn: Self = Self(0);
    pub const kAdiPortTypeAnalogOut: Self = Self(1);
    pub const kAdiPortTypeDigitalIn: Self = Self(2);
    pub const kAdiPortTypeDigitalOut: Self = Self(3);
    pub const kAdiPortTypeSmartButton: Self = Self(4);
    pub const kAdiPortTypeSmartPot: Self = Self(5);
    pub const kAdiPortTypeLegacyButton: Self = Self(6);
    pub const kAdiPortTypeLegacyPotentiometer: Self = Self(7);
    pub const kAdiPortTypeLegacyLineSensor: Self = Self(8);
    pub const kAdiPortTypeLegacyLightSensor: Self = Self(9);
    pub const kAdiPortTypeLegacyGyro: Self = Self(10);
    pub const kAdiPortTypeLegacyAccelerometer: Self = Self(11);
    pub const kAdiPortTypeLegacyServo: Self = Self(12);
    pub const kAdiPortTypeLegacyPwm: Self = Self(13);
    pub const kAdiPortTypeQuadEncoder: Self = Self(14);
    pub const kAdiPortTypeSonar: Self = Self(15);
    pub const kAdiPortTypeLegacyPwmSlew: Self = Self(16);
    pub const kAdiPortTypeUndefined: Self = Self(255);
}

#[repr(transparent)]
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct V5_DeviceBumperState(pub core::ffi::c_uchar);

impl V5_DeviceBumperState {
    pub const kBumperReleased: Self = Self(0);
    pub const kBumperPressed: Self = Self(1);
}

unsafe extern "system" {
    pub fn vexDeviceAdiPortConfigSet(
        device: V5_DeviceT,
        port: u32,
        config: V5_AdiPortConfiguration,
    );
    pub fn vexDeviceAdiPortConfigGet(device: V5_DeviceT, port: u32) -> V5_AdiPortConfiguration;
    pub fn vexDeviceAdiValueSet(device: V5_DeviceT, port: u32, value: i32);
    pub fn vexDeviceAdiValueGet(device: V5_DeviceT, port: u32) -> i32;
    pub fn vexDeviceAdiAddrLedSet(
        device: V5_DeviceT,
        port: u32,
        pData: *mut u32,
        nOffset: u32,
        nLength: u32,
        options: u32,
    );
    pub fn vexDeviceBumperGet(device: V5_DeviceT) -> V5_DeviceBumperState;
    pub fn vexDeviceGyroReset(device: V5_DeviceT);
    pub fn vexDeviceGyroHeadingGet(device: V5_DeviceT) -> c_double;
    pub fn vexDeviceGyroDegreesGet(device: V5_DeviceT) -> c_double;
    pub fn vexDeviceSonarValueGet(device: V5_DeviceT) -> i32;
}
