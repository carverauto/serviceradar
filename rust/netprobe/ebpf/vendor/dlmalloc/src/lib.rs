//! A Rust port of the `dlmalloc` allocator.
//!
//! The `dlmalloc` allocator is described at
//! <https://gee.cs.oswego.edu/dl/html/malloc.html> and this Rust crate is a straight
//! port of the C code for the allocator into Rust. The implementation is
//! wrapped up in a `Dlmalloc` type and has support for Linux, OSX, and Wasm
//! currently.
//!
//! The primary purpose of this crate is that it serves as the default memory
//! allocator for the `wasm32-unknown-unknown` target in the standard library.
//! Support for other platforms is largely untested and unused, but is used when
//! testing this crate.

#![allow(dead_code)]
#![no_std]
#![deny(missing_docs)]
#![cfg_attr(target_arch = "wasm64", feature(simd_wasm64))]

use core::cmp;
use core::ptr;
use sys::System;

#[cfg(feature = "global")]
pub use self::global::{enable_alloc_after_fork, GlobalDlmalloc};

mod dlmalloc;
#[cfg(feature = "global")]
mod global;

/// In order for this crate to efficiently manage memory, it needs a way to communicate with the
/// underlying platform. This `Allocator` trait provides an interface for this communication.
pub unsafe trait Allocator: Send {
    /// Allocates system memory region of at least `size` bytes
    /// Returns a triple of `(base, size, flags)` where `base` is a pointer to the beginning of the
    /// allocated memory region. `size` is the actual size of the region while `flags` specifies
    /// properties of the allocated region. If `EXTERN_BIT` (bit 0) set in flags, then we did not
    /// allocate this segment and so should not try to deallocate or merge with others.
    /// This function can return a `std::ptr::null_mut()` when allocation fails (other values of
    /// the triple will be ignored).
    fn alloc(&self, size: usize) -> (*mut u8, usize, u32);

    /// Remaps system memory region at `ptr` with size `oldsize` to a potential new location with
    /// size `newsize`. `can_move` indicates if the location is allowed to move to a completely new
    /// location, or that it is only allowed to change in size. Returns a pointer to the new
    /// location in memory.
    /// This function can return a `std::ptr::null_mut()` to signal an error.
    fn remap(&self, ptr: *mut u8, oldsize: usize, newsize: usize, can_move: bool) -> *mut u8;

    /// Frees a part of a memory chunk. The original memory chunk starts at `ptr` with size `oldsize`
    /// and is turned into a memory region starting at the same address but with `newsize` bytes.
    /// Returns `true` iff the access memory region could be freed.
    fn free_part(&self, ptr: *mut u8, oldsize: usize, newsize: usize) -> bool;

    /// Frees an entire memory region. Returns `true` iff the operation succeeded. When `false` is
    /// returned, the `dlmalloc` may re-use the location on future allocation requests
    fn free(&self, ptr: *mut u8, size: usize) -> bool;

    /// Indicates if the system can release a part of memory. For the `flags` argument, see
    /// `Allocator::alloc`
    fn can_release_part(&self, flags: u32) -> bool;

    /// Indicates whether newly allocated regions contain zeros.
    fn allocates_zeros(&self) -> bool;

    /// Returns the page size. Must be a power of two
    fn page_size(&self) -> usize;
}

/// An allocator instance
///
/// Instances of this type are used to allocate blocks of memory. For best
/// results only use one of these. Currently doesn't implement `Drop` to release
/// lingering memory back to the OS. That may happen eventually though!
pub struct Dlmalloc<A = System>(dlmalloc::Dlmalloc<A>);

cfg_if::cfg_if! {
    if #[cfg(target_family = "wasm")] {
        #[path = "wasm.rs"]
        mod sys;
    } else if #[cfg(target_os = "windows")] {
        #[path = "windows.rs"]
        mod sys;
    } else if #[cfg(target_os = "xous")] {
        #[path = "xous.rs"]
        mod sys;
    } else if #[cfg(any(target_os = "linux", target_os = "macos"))] {
        #[path = "unix.rs"]
        mod sys;
    } else {
        #[path = "dummy.rs"]
        mod sys;
    }
}

impl Dlmalloc<System> {
    /// Creates a new instance of an allocator
    pub const fn new() -> Dlmalloc<System> {
        Dlmalloc(dlmalloc::Dlmalloc::new(System::new()))
    }
}

impl<A> Dlmalloc<A> {
    /// Creates a new instance of an allocator
    pub const fn new_with_allocator(sys_allocator: A) -> Dlmalloc<A> {
        Dlmalloc(dlmalloc::Dlmalloc::new(sys_allocator))
    }
}

impl<A: Allocator> Dlmalloc<A> {
    /// Allocates `size` bytes with `align` align.
    ///
    /// Returns a null pointer if allocation fails. Returns a valid pointer
    /// otherwise.
    ///
    /// Safety and contracts are largely governed by the `GlobalAlloc::alloc`
    /// method contracts.
    #[inline]
    pub unsafe fn malloc(&mut self, size: usize, align: usize) -> *mut u8 {
        if align <= self.0.malloc_alignment() {
            self.0.malloc(size)
        } else {
            self.0.memalign(align, size)
        }
    }

    /// Same as `malloc`, except if the allocation succeeds it's guaranteed to
    /// point to `size` bytes of zeros.
    #[inline]
    pub unsafe fn calloc(&mut self, size: usize, align: usize) -> *mut u8 {
        let ptr = self.malloc(size, align);
        if !ptr.is_null() && self.0.calloc_must_clear(ptr) {
            ptr::write_bytes(ptr, 0, size);
        }
        ptr
    }

    /// Deallocates a `ptr` with `size` and `align` as the previous request used
    /// to allocate it.
    ///
    /// Safety and contracts are largely governed by the `GlobalAlloc::dealloc`
    /// method contracts.
    #[inline]
    pub unsafe fn free(&mut self, ptr: *mut u8, size: usize, align: usize) {
        let _ = align;
        self.0.validate_size(ptr, size);
        self.0.free(ptr)
    }

    /// Reallocates `ptr`, a previous allocation with `old_size` and
    /// `old_align`, to have `new_size` and the same alignment as before.
    ///
    /// Returns a null pointer if the memory couldn't be reallocated, but `ptr`
    /// is still valid. Returns a valid pointer and frees `ptr` if the request
    /// is satisfied.
    ///
    /// Safety and contracts are largely governed by the `GlobalAlloc::realloc`
    /// method contracts.
    #[inline]
    pub unsafe fn realloc(
        &mut self,
        ptr: *mut u8,
        old_size: usize,
        old_align: usize,
        new_size: usize,
    ) -> *mut u8 {
        self.0.validate_size(ptr, old_size);

        if old_align <= self.0.malloc_alignment() {
            self.0.realloc(ptr, new_size)
        } else {
            let res = self.malloc(new_size, old_align);
            if !res.is_null() {
                let size = cmp::min(old_size, new_size);
                ptr::copy_nonoverlapping(ptr, res, size);
                self.free(ptr, old_size, old_align);
            }
            res
        }
    }

    /// If possible, gives memory back to the system if there is unused memory
    /// at the high end of the malloc pool or in unused segments.
    ///
    /// You can call this after freeing large blocks of memory to potentially
    /// reduce the system-level memory requirements of a program. However, it
    /// cannot guarantee to reduce memory. Under some allocation patterns, some
    /// large free blocks of memory will be locked between two used chunks, so
    /// they cannot be given back to the system.
    ///
    /// The `pad` argument represents the amount of free trailing space to
    /// leave untrimmed. If this argument is zero, only the minimum amount of
    /// memory to maintain internal data structures will be left. Non-zero
    /// arguments can be supplied to maintain enough trailing space to service
    /// future expected allocations without having to re-obtain memory from the
    /// system.
    ///
    /// Returns `true` if it actually released any memory, else `false`.
    pub unsafe fn trim(&mut self, pad: usize) -> bool {
        self.0.trim(pad)
    }

    /// Releases all allocations in this allocator back to the system,
    /// consuming self and preventing further use.
    ///
    /// Returns the number of bytes released to the system.
    pub unsafe fn destroy(self) -> usize {
        self.0.destroy()
    }

    /// Get a reference to the underlying [`Allocator`] that this `Dlmalloc` was
    /// constructed with.
    pub fn allocator(&self) -> &A {
        self.0.allocator()
    }

    /// Get a mutable reference to the underlying [`Allocator`] that this
    /// `Dlmalloc` was constructed with.
    pub fn allocator_mut(&mut self) -> &mut A {
        self.0.allocator_mut()
    }
}
