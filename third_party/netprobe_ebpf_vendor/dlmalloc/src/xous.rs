use crate::Allocator;
use core::ptr;

pub struct System {
    _priv: (),
}

impl System {
    pub const fn new() -> System {
        System { _priv: () }
    }
}

#[cfg(target_arch = "riscv32")]
mod sys {
    use core::arch::asm;

    pub fn increase_heap(length: usize) -> Result<(usize, usize), ()> {
        let syscall_no_increase_heap = 10usize;
        let memory_flags_read_write = 2usize | 4usize;

        let mut a0 = syscall_no_increase_heap;
        let mut a1 = length;
        let mut a2 = memory_flags_read_write;

        unsafe {
            asm!(
                "ecall",
                inlateout("a0") a0,
                inlateout("a1") a1,
                inlateout("a2") a2,
                out("a3") _,
                out("a4") _,
                out("a5") _,
                out("a6") _,
                out("a7") _,
            )
        };

        let result = a0;
        let address = a1;
        let length = a2;

        // 3 is the "MemoryRange" type, and the result is only valid
        // if we get nonzero address and length.
        if result == 3 && address != 0 && length != 0 {
            Ok((address, length))
        } else {
            Err(())
        }
    }
}

unsafe impl Allocator for System {
    /// Allocate an additional `size` bytes on the heap, and return a new
    /// chunk of memory, as well as the size of the allocation and some
    /// flags. Since flags are unused on this platform, they will always
    /// be `0`.
    fn alloc(&self, size: usize) -> (*mut u8, usize, u32) {
        let size = if size == 0 {
            4096
        } else if size & 4095 == 0 {
            size
        } else {
            size + (4096 - (size & 4095))
        };

        if let Ok((address, length)) = sys::increase_heap(size) {
            let start = address - size + length;
            (start as *mut u8, size, 0)
        } else {
            (ptr::null_mut(), 0, 0)
        }
    }

    fn remap(&self, _ptr: *mut u8, _oldsize: usize, _newsize: usize, _can_move: bool) -> *mut u8 {
        // TODO
        ptr::null_mut()
    }

    fn free_part(&self, _ptr: *mut u8, _oldsize: usize, _newsize: usize) -> bool {
        false
    }

    fn free(&self, _ptr: *mut u8, _size: usize) -> bool {
        false
    }

    fn can_release_part(&self, _flags: u32) -> bool {
        false
    }

    fn allocates_zeros(&self) -> bool {
        true
    }

    fn page_size(&self) -> usize {
        4 * 1024
    }
}

#[cfg(feature = "global")]
pub fn acquire_global_lock() {
    // global feature should not be enabled
    unimplemented!()
}

#[cfg(feature = "global")]
pub fn release_global_lock() {
    // global feature should not be enabled
    unimplemented!()
}

#[cfg(feature = "global")]
pub unsafe fn enable_alloc_after_fork() {
    // platform does not support `fork()` call
}
