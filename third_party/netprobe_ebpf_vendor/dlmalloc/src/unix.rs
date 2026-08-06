use crate::Allocator;
use core::ptr;

/// System setting for Linux
pub struct System {
    _priv: (),
}

impl System {
    pub const fn new() -> System {
        System { _priv: () }
    }
}

#[cfg(feature = "global")]
static mut LOCK: libc::pthread_mutex_t = libc::PTHREAD_MUTEX_INITIALIZER;

unsafe impl Allocator for System {
    fn alloc(&self, size: usize) -> (*mut u8, usize, u32) {
        let addr = unsafe {
            libc::mmap(
                ptr::null_mut(),
                size,
                libc::PROT_WRITE | libc::PROT_READ,
                libc::MAP_ANON | libc::MAP_PRIVATE,
                -1,
                0,
            )
        };
        if addr == libc::MAP_FAILED {
            (ptr::null_mut(), 0, 0)
        } else {
            (addr.cast(), size, 0)
        }
    }

    #[cfg(target_os = "linux")]
    fn remap(&self, ptr: *mut u8, oldsize: usize, newsize: usize, can_move: bool) -> *mut u8 {
        let flags = if can_move { libc::MREMAP_MAYMOVE } else { 0 };
        let ptr = unsafe { libc::mremap(ptr.cast(), oldsize, newsize, flags) };
        if ptr == libc::MAP_FAILED {
            ptr::null_mut()
        } else {
            ptr.cast()
        }
    }

    #[cfg(target_os = "macos")]
    fn remap(&self, _ptr: *mut u8, _oldsize: usize, _newsize: usize, _can_move: bool) -> *mut u8 {
        ptr::null_mut()
    }

    #[cfg(target_os = "linux")]
    fn free_part(&self, ptr: *mut u8, oldsize: usize, newsize: usize) -> bool {
        unsafe {
            let rc = libc::mremap(ptr.cast(), oldsize, newsize, 0);
            if rc != libc::MAP_FAILED {
                return true;
            }
            libc::munmap(ptr.add(newsize).cast(), oldsize - newsize) == 0
        }
    }

    #[cfg(target_os = "macos")]
    fn free_part(&self, ptr: *mut u8, oldsize: usize, newsize: usize) -> bool {
        unsafe { libc::munmap(ptr.add(newsize).cast(), oldsize - newsize) == 0 }
    }

    fn free(&self, ptr: *mut u8, size: usize) -> bool {
        unsafe { libc::munmap(ptr.cast(), size) == 0 }
    }

    fn can_release_part(&self, _flags: u32) -> bool {
        true
    }

    fn allocates_zeros(&self) -> bool {
        true
    }

    fn page_size(&self) -> usize {
        4096
    }
}

#[cfg(feature = "global")]
pub fn acquire_global_lock() {
    unsafe { assert_eq!(libc::pthread_mutex_lock(ptr::addr_of_mut!(LOCK)), 0) }
}

#[cfg(feature = "global")]
pub fn release_global_lock() {
    unsafe { assert_eq!(libc::pthread_mutex_unlock(ptr::addr_of_mut!(LOCK)), 0) }
}

#[cfg(feature = "global")]
/// allows the allocator to remain unsable in the child process,
/// after a call to `fork(2)`
///
/// #Safety
///
/// if used, this function must be called,
/// before any allocations are made with the global allocator.
pub unsafe fn enable_alloc_after_fork() {
    // atfork must only be called once, to avoid a deadlock,
    // where the handler attempts to acquire the global lock twice
    static mut FORK_PROTECTED: bool = false;

    unsafe extern "C" fn _acquire_global_lock() {
        acquire_global_lock()
    }

    unsafe extern "C" fn _release_global_lock() {
        release_global_lock()
    }

    acquire_global_lock();
    // if a process forks,
    // it will acquire the lock before any other thread,
    // protecting it from deadlock,
    // due to the child being created with only the calling thread.
    if !FORK_PROTECTED {
        libc::pthread_atfork(
            Some(_acquire_global_lock),
            Some(_release_global_lock),
            Some(_release_global_lock),
        );
        FORK_PROTECTED = true;
    }
    release_global_lock();
}
