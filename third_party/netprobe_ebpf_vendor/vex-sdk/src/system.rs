//! VEXos System Functions

use core::ffi::{c_char, c_void};

/// Code Signature
///
/// The first 16 bytes of a user code binary should contain the user code
/// signature.  For simple user code programs this will be created by the
/// startup code in the runtime library, certain types of user code,
/// for example a virtual machine, may override the default settings to cause
/// the V5 system code to enable custom functionality yet TBD.
#[repr(C, packed)]
#[derive(Copy, Clone, Eq, PartialEq, Debug)]
pub struct vcodesig {
    /// Magic, must be 'VXV5' 0x35565856 le
    pub magic: u32,

    /// Program type
    pub r#type: u32,

    /// Program originator
    pub owner: u32,

    /// Program options
    pub options: u32,
}

impl Default for vcodesig {
    fn default() -> Self {
        vcodesig {
            magic: V5_SIG_MAGIC,
            r#type: Default::default(),
            owner: Default::default(),
            options: Default::default(),
        }
    }
}

pub const V5_SIG_MAGIC: u32 = 0x35585658;
pub const EX_SIG_MAGIC: u32 = 0x45585658;

pub const V5_SIG_TYPE_USER: u32 = 0;
pub const V5_SIG_OWNER_SYS: u32 = 0;
pub const V5_SIG_OWNER_VEX: u32 = 1;
pub const V5_SIG_OWNER_PARTNER: u32 = 2;
pub const V5_SIG_OPTIONS_NONE: u32 = 0;
/// Invert default graphics colors
pub const V5_SIG_OPTIONS_INDG: u32 = 1 << 0;
/// Kill threads when main exits
pub const V5_SIG_OPTIONS_EXIT: u32 = 1 << 1;
/// Invert graphics based on theme
pub const V5_SIG_OPTIONS_THDG: u32 = 1 << 2;

#[repr(C)]
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct time {
    /// Hours
    pub ti_hour: u8,
    /// Minutes
    pub ti_min: u8,
    /// Seconds
    pub ti_sec: u8,
    /// Hundredths of seconds
    pub ti_hund: u8,
}

#[repr(C)]
#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
pub struct date {
    /// Year - 1980
    pub da_year: u16,
    /// Day of the month
    pub da_day: u8,
    /// Month (1 = Jan)
    pub da_mon: u8,
}

unsafe extern "system" {
    pub fn vexScratchMemoryPtr(ptr: *mut *mut core::ffi::c_void) -> i32;
    pub fn vexScratchMemoryLock() -> bool;
    pub fn vexScratchMemoryUnlock();
    pub fn vexSystemTimeGet() -> u32;
    pub fn vexGettime() -> time;
    pub fn vexGetdate() -> date;
    pub fn vexSystemMemoryDump();
    pub fn vexSystemDigitalIO(pin: u32, value: u32);
    pub fn vexSystemStartupOptions() -> u32;
    pub fn vexSystemExitRequest();
    pub fn vexSystemHighResTimeGet() -> u64;
    pub fn vexSystemPowerupTimeGet() -> u64;
    pub fn vexSystemLinkAddrGet() -> u32;
    pub fn vexSystemUsbStatus() -> u32;
    pub fn vexSystemTimerStop();
    pub fn vexSystemTimerClearInterrupt();
    pub fn vexSystemTimerReinitForRtos(
        priority: u32,
        handler: extern "system" fn(data: *mut c_void),
    ) -> i32;
    pub fn vexSystemApplicationIRQHandler(ulICCIAR: u32);
    pub fn vexSystemWatchdogReinitRtos() -> i32;
    pub fn vexSystemWatchdogGet() -> u32;
    pub fn vexSystemBoot();
    pub fn vexSystemUndefinedException();
    pub fn vexSystemFIQInterrupt();
    pub fn vexSystemIQRQnterrupt();
    pub fn vexSystemSWInterrupt();
    pub fn vexSystemDataAbortInterrupt();
    pub fn vexSystemPrefetchAbortInterrupt();
    pub fn vexSystemVersion() -> u32;
    pub fn vexStdlibVersion() -> u32;
}

unsafe extern "C" {
    pub fn vex_printf(format: *const c_char, ...) -> i32;
    pub fn vex_sprintf(out: *mut c_char, format: *const c_char, ...) -> i32;
    pub fn vex_snprintf(out: *mut c_char, max_len: u32, format: *const c_char, ...) -> i32;
}
