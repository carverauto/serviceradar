//! Filesystem Access

use core::ffi::c_char;

#[derive(Default, Debug, Copy, Clone, Eq, PartialEq)]
#[repr(transparent)]
pub struct FRESULT(pub core::ffi::c_uchar);

impl FRESULT {
    pub const FR_OK: Self = Self(0);
    pub const FR_DISK_ERR: Self = Self(1);
    pub const FR_INT_ERR: Self = Self(2);
    pub const FR_NOT_READY: Self = Self(3);
    pub const FR_NO_FILE: Self = Self(4);
    pub const FR_NO_PATH: Self = Self(5);
    pub const FR_INVALID_NAME: Self = Self(6);
    pub const FR_DENIED: Self = Self(7);
    pub const FR_EXIST: Self = Self(8);
    pub const FR_INVALID_OBJECT: Self = Self(9);
    pub const FR_WRITE_PROTECTED: Self = Self(10);
    pub const FR_INVALID_DRIVE: Self = Self(11);
    pub const FR_NOT_ENABLED: Self = Self(12);
    pub const FR_NO_FILESYSTEM: Self = Self(13);
    pub const FR_MKFS_ABORTED: Self = Self(14);
    pub const FR_TIMEOUT: Self = Self(15);
    pub const FR_LOCKED: Self = Self(16);
    pub const FR_NOT_ENOUGH_CORE: Self = Self(17);
    pub const FR_TOO_MANY_OPEN_FILES: Self = Self(18);
    pub const FR_INVALID_PARAMETER: Self = Self(19);
}
pub type FIL = core::ffi::c_void;

unsafe extern "system" {
    pub fn vexFileMountSD() -> FRESULT;
    pub fn vexFileDirectoryGet(path: *const c_char, buffer: *mut c_char, len: u32) -> FRESULT;
    pub fn vexFileOpen(filename: *const c_char, mode: *const c_char) -> *mut FIL;
    pub fn vexFileOpenWrite(filename: *const c_char) -> *mut FIL;
    pub fn vexFileOpenCreate(filename: *const c_char) -> *mut FIL;
    pub fn vexFileClose(fdp: *mut FIL);
    pub fn vexFileWrite(buf: *mut c_char, size: u32, nItems: u32, fdp: *mut FIL) -> i32;
    pub fn vexFileSize(fdp: *mut FIL) -> i32;
    pub fn vexFileSeek(fdp: *mut FIL, offset: u32, whence: i32) -> FRESULT;
    pub fn vexFileRead(buf: *mut c_char, size: u32, nItems: u32, fdp: *mut FIL) -> i32;
    pub fn vexFileDriveStatus(drive: u32) -> bool;
    pub fn vexFileTell(fdp: *mut FIL) -> i32;
    pub fn vexFileSync(fdp: *mut FIL);
    pub fn vexFileStatus(filename: *const c_char) -> u32;
}
