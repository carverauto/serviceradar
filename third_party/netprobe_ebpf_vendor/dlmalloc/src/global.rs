use crate::Dlmalloc;
use core::alloc::{GlobalAlloc, Layout};
use core::ptr;

pub use crate::sys::enable_alloc_after_fork;

/// An instance of a "global allocator" backed by `Dlmalloc`
///
/// This API requires the `global` feature is activated, and this type
/// implements the `GlobalAlloc` trait in the standard library.
pub struct GlobalDlmalloc;

static mut DLMALLOC: Dlmalloc = Dlmalloc::new();

unsafe impl GlobalAlloc for GlobalDlmalloc {
    #[inline]
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let _guard = lock();
        let dlmalloc = ptr::addr_of_mut!(DLMALLOC);
        (*dlmalloc).malloc(layout.size(), layout.align())
    }

    #[inline]
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        let _guard = lock();
        let dlmalloc = ptr::addr_of_mut!(DLMALLOC);
        (*dlmalloc).free(ptr, layout.size(), layout.align())
    }

    #[inline]
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let _guard = lock();
        let dlmalloc = ptr::addr_of_mut!(DLMALLOC);
        (*dlmalloc).calloc(layout.size(), layout.align())
    }

    #[inline]
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let _guard = lock();
        let dlmalloc = ptr::addr_of_mut!(DLMALLOC);
        (*dlmalloc).realloc(ptr, layout.size(), layout.align(), new_size)
    }
}

unsafe fn lock() -> impl Drop {
    crate::sys::acquire_global_lock();

    struct Guard;
    impl Drop for Guard {
        fn drop(&mut self) {
            crate::sys::release_global_lock()
        }
    }

    Guard
}
