use crate::Allocator;
use core::mem::MaybeUninit;
use core::ptr;
use windows_sys::Win32::System::Memory::*;
use windows_sys::Win32::System::SystemInformation::*;
#[cfg(feature = "global")]
use windows_sys::Win32::System::Threading::*;

pub struct System {
    _priv: (),
}

impl System {
    pub const fn new() -> System {
        System { _priv: () }
    }
}

unsafe impl Allocator for System {
    fn alloc(&self, size: usize) -> (*mut u8, usize, u32) {
        let addr = unsafe {
            VirtualAlloc(
                ptr::null_mut(),
                size,
                MEM_RESERVE | MEM_COMMIT,
                PAGE_READWRITE,
            )
        };

        if addr.is_null() {
            (ptr::null_mut(), 0, 0)
        } else {
            (addr.cast(), size, 0)
        }
    }

    fn remap(&self, _ptr: *mut u8, _oldsize: usize, _newsize: usize, _can_move: bool) -> *mut u8 {
        ptr::null_mut()
    }

    fn free_part(&self, ptr: *mut u8, oldsize: usize, newsize: usize) -> bool {
        unsafe { VirtualFree(ptr.add(newsize).cast(), oldsize - newsize, MEM_DECOMMIT) != 0 }
    }

    fn free(&self, ptr: *mut u8, _size: usize) -> bool {
        unsafe { VirtualFree(ptr.cast(), 0, MEM_DECOMMIT) != 0 }
    }

    fn can_release_part(&self, _flags: u32) -> bool {
        true
    }

    fn allocates_zeros(&self) -> bool {
        true
    }

    fn page_size(&self) -> usize {
        unsafe {
            let mut info = MaybeUninit::uninit();
            GetSystemInfo(info.as_mut_ptr());
            info.assume_init_ref().dwPageSize as usize
        }
    }
}

// NB: `SRWLOCK_INIT` doesn't appear to be in `windows-sys`
#[cfg(feature = "global")]
static mut LOCK: SRWLOCK = SRWLOCK {
    Ptr: ptr::null_mut(),
};

#[cfg(feature = "global")]
pub fn acquire_global_lock() {
    unsafe {
        AcquireSRWLockExclusive(ptr::addr_of_mut!(LOCK));
    }
}

#[cfg(feature = "global")]
pub fn release_global_lock() {
    unsafe {
        ReleaseSRWLockExclusive(ptr::addr_of_mut!(LOCK));
    }
}

/// Not needed on Windows
#[cfg(feature = "global")]
pub unsafe fn enable_alloc_after_fork() {}
