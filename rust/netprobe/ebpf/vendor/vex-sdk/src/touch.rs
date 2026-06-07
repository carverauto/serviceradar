//! Brain Screen Touchscreen

#[repr(transparent)]
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct V5_TouchEvent(pub core::ffi::c_uchar);

impl V5_TouchEvent {
    pub const kTouchEventRelease: Self = Self(0);
    pub const kTouchEventPress: Self = Self(1);
    pub const kTouchEventPressAuto: Self = Self(2);
}

#[repr(C)]
#[derive(Default, Copy, Clone, Eq, PartialEq, Debug)]
pub struct V5_TouchStatus {
    pub lastEvent: V5_TouchEvent,
    pub lastXpos: i16,
    pub lastYpos: i16,
    pub pressCount: i32,
    pub releaseCount: i32,
}

unsafe extern "system" {
    pub fn vexTouchUserCallbackSet(callback: unsafe extern "system" fn(V5_TouchEvent, i32, i32));
    pub fn vexTouchDataGet(status: *mut V5_TouchStatus);
}
