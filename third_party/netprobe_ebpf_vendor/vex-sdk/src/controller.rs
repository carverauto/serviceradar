//! V5 Controller

#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
#[repr(transparent)]
pub struct V5_ControllerId(pub core::ffi::c_uchar);

impl V5_ControllerId {
    pub const kControllerMaster: Self = Self(0);
    pub const kControllerPartner: Self = Self(1);
}

#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
#[repr(transparent)]
pub struct V5_ControllerStatus(pub core::ffi::c_uchar);

impl V5_ControllerStatus {
    pub const kV5ControllerOffline: Self = Self(0);
    pub const kV5ControllerTethered: Self = Self(1);
    pub const kV5ControllerVexnet: Self = Self(2);
}

#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
#[repr(transparent)]
pub struct V5_ControllerIndex(pub core::ffi::c_uchar);

impl V5_ControllerIndex {
    pub const AnaLeftX: Self = Self(0);
    pub const AnaLeftY: Self = Self(1);
    pub const AnaRightX: Self = Self(2);
    pub const AnaRightY: Self = Self(3);
    pub const AnaSpare1: Self = Self(4);
    pub const AnaSpare2: Self = Self(5);
    pub const Button5U: Self = Self(6);
    pub const Button5D: Self = Self(7);
    pub const Button6U: Self = Self(8);
    pub const Button6D: Self = Self(9);
    pub const Button7U: Self = Self(10);
    pub const Button7D: Self = Self(11);
    pub const Button7L: Self = Self(12);
    pub const Button7R: Self = Self(13);
    pub const Button8U: Self = Self(14);
    pub const Button8D: Self = Self(15);
    pub const Button8L: Self = Self(16);
    pub const Button8R: Self = Self(17);
    pub const ButtonSEL: Self = Self(18);
    pub const BatteryLevel: Self = Self(19);
    pub const ButtonAll: Self = Self(20);
    pub const Flags: Self = Self(21);
    pub const BatteryCapacity: Self = Self(22);
    pub const Axis1: Self = Self::AnaRightX;
    pub const Axis2: Self = Self::AnaRightY;
    pub const Axis3: Self = Self::AnaLeftY;
    pub const Axis4: Self = Self::AnaLeftX;
    pub const ButtonL1: Self = Self::Button5U;
    pub const ButtonL2: Self = Self::Button5D;
    pub const ButtonR1: Self = Self::Button6U;
    pub const ButtonR2: Self = Self::Button6D;
    pub const ButtonUp: Self = Self::Button7U;
    pub const ButtonDown: Self = Self::Button7D;
    pub const ButtonLeft: Self = Self::Button7L;
    pub const ButtonRight: Self = Self::Button7R;
    pub const ButtonX: Self = Self::Button8U;
    pub const ButtonB: Self = Self::Button8D;
    pub const ButtonY: Self = Self::Button8L;
    pub const ButtonA: Self = Self::Button8R;
}

unsafe extern "system" {
    pub fn vexControllerGet(id: V5_ControllerId, index: V5_ControllerIndex) -> i32;
    pub fn vexControllerConnectionStatusGet(id: V5_ControllerId) -> V5_ControllerStatus;
    pub fn vexControllerTextSet(id: u32, line: u32, col: u32, buf: *const u8) -> u32;
}
