//! Global Allocator Bridge
//!
//! This module provides a bridge between the global-allocator interface of
//! the rust standard library and the allocators of this crate. The stabilized
//! interface of the rust compiler and standard-library to the global allocator
//! is provided by the `core::alloc::GlobalAlloc` trait and the
//! `global_allocator` attribute. The types provided by this module implement
//! this trait and can be used to register a global allocator.
//!
//! Only one crate in every dependency graph can use the `global_allocator`
//! attribute to mark one static variable as the global allocator of the entire
//! application. The type of it must implement `GlobalAlloc`. Note that this
//! attribute can only be used in the crate-root, not in sub-modules.
//!
//! UEFI is, however, not a natural fit for the global-allocator trait. On UEFI
//! systems, access to all system APIs is done through the system table, which
//! is passed as argument to the application entry-point. Therefore, it is up
//! to the implementor of the entry-point to set up the global state inherent
//! to rust's global allocator.
//!
//! # Examples
//!
//! The following UEFI application simply registers an allocator with its
//! system-table and then invokes `uefi_run()`. The latter can then operate
//! under the assumption that an allocator is available and ready. Once the
//! function returns, the allocator is automatically torn down.
//!
//! This is a typical use of the `r-efi-alloc` crate. Only applications that
//! actually exit the boot-services, or access UEFI outside of regular UEFI
//! application and driver environments will have to use the custom allocator
//! interfaces.
//!
//! ```ignore
//! #![no_main]
//! #![no_std]
//!
//! use r_efi::efi;
//! use r_efi_alloc::{alloc::Allocator, global::Bridge};
//!
//! #[global_allocator]
//! static GLOBAL_ALLOCATOR: Bridge = Bridge::new();
//!
//! #[no_mangle]
//! pub extern "C" fn efi_main(
//!     h: efi::Handle,
//!     st: *mut efi::SystemTable,
//! ) -> efi::Status {
//!     unsafe {
//!         let mut allocator = Allocator::from_system_table(st, efi::LOADER_DATA);
//!         let _attachment = GLOBAL_ALLOCATOR.attach(&mut allocator);
//!
//!         efi_run(h, st)
//!     }
//! }
//!
//! pub fn efi_run(h: efi::Handle, st: *mut efi::SystemTable) -> efi::Status {
//!     ...
//! }
//! ```

use core::sync::atomic;

/// Bridge for Global Allocators
///
/// This bridge connects static allocator variables to the dynamic UEFI
/// allocator interfaces. The bridge object implements the `GlobalAlloc`
/// interface and can thus be marked as `global_allocator`.
///
/// The need for a bridge arises from the fact that UEFI requires access to
/// the system-table to allocate memory, and the system-table is only available
/// as argument to the entry-point. Hence, this bridge represents a dynamic
/// link between the global allocator and a runtime allocator created by the
/// application.
///
/// The main API of the bridge is the `attach()` function, which allows to
/// attach an allocator to the bridge, which is thereon used for allocations.
/// Only a single allocator can be attached to a bridge at a time, and any
/// global allocations will fail if no allocator is attached.
///
/// The `attach()` operation returns an object that represents the attachment.
/// To release it, the attachment object has to be dropped. Note that the
/// caller must ensure that any global allocator is released before an
/// allocator attachment is released.
pub struct Bridge {
    attachment: atomic::AtomicPtr<crate::alloc::Allocator>,
}

/// Bridge Attachment
///
/// This type represents the attachment of an allocator to a bridge. It is
/// returned by the `attach()` operation of a bridge. This type has no exposed
/// API other than a custom `drop()` implementation, which releases the
/// attachment.
pub struct Attachment<'alloc, 'bridge> {
    allocator: &'alloc mut crate::alloc::Allocator,
    bridge: &'bridge Bridge,
}

impl Bridge {
    /// Create Bridge
    ///
    /// The Bridge type represents the global allocator. Since the latter
    /// cannot be instantiated at compile-time (on UEFI the system-table
    /// address can only be resolved at runtime, since it is passed as argument
    /// to the entry point), it is implemented as a bridge between the actual
    /// allocator object and the global allocator. By default, the bridge
    /// object has no allocator linked. Any allocation requests will thusly
    /// yield an allocation error.
    ///
    /// To make use of a bridge, you have to instantiate an allocator object
    /// and attach it via the `attach()` method.
    ///
    /// You can create as many bridges as you like. However, to mark a bridge
    /// as global allocator, you have to make it a global, static variable and
    /// annotate it with `#[global_allocator]`. Only one such variable is
    /// allowed to exist in any crate tree, and it must be declared in the root
    /// module of a given crate.
    pub const fn new() -> Bridge {
        Bridge {
            attachment: atomic::AtomicPtr::new(core::ptr::null_mut()),
        }
    }

    unsafe fn raw_attach(&self, ptr: *mut crate::alloc::Allocator) -> Option<()> {
        // Set @ptr as the attachment on this bridge. This only succeeds if
        // there is not already an attachment set.
        // We use a compare_exchange() to change the attachment if it was NULL.
        // We use Release semantics, so any stores to your allocator are
        // visible once the attachment is written. On error, no ordering
        // guarantees are given, since this interface is not meant to be a
        // programmatic query.
        // Note that the Release pairs with the Acquire in the GlobalAlloc
        // trait below.
        //
        // This interface is unsafe since the caller must guarantee to detach
        // the bridge before it is destroyed. There are no runtime guarantees
        // given by this interface, it is all left to the caller.
        let p = self.attachment.compare_exchange(
            core::ptr::null_mut(),
            ptr,
            atomic::Ordering::Release,
            atomic::Ordering::Relaxed,
        );

        if p.is_ok() {
            Some(())
        } else {
            None
        }
    }

    unsafe fn raw_detach(&self, ptr: *mut crate::alloc::Allocator) {
        // Detach @ptr from this bridge. The caller must guarantee @ptr is
        // already attached to the bridge. This function will panic if @ptr is
        // not the current attachment.
        //
        // We use compare_exchange() to replace the old attachment with NULL.
        // If it was not NULL, we panic. No ordering guarantees are required,
        // since there is no dependent state.
        let p = self.attachment.compare_exchange(
            ptr,
            core::ptr::null_mut(),
            atomic::Ordering::Relaxed,
            atomic::Ordering::Relaxed,
        );
        assert!(p.is_ok());
    }

    /// Attach an allocator
    ///
    /// This attaches the allocator given as @allocator to the bridge. If there
    /// is an allocator attached already, this will yield `None`. Otherwise, an
    /// attachment is returned that represents this link. Dropping the
    /// attachment will detach the allocator from the bridge.
    ///
    /// As long as an allocator is attached to a bridge, allocations through
    /// this bridge (via rust's `GlobalAlloc` trait) will be served by this
    /// allocator.
    ///
    /// This is an unsafe interface. It is the caller's responsibility to
    /// guarantee that the attachment survives all outstanding allocations.
    /// That is, any allocated memory must be released before detaching the
    /// allocator.
    pub unsafe fn attach<'alloc, 'bridge>(
        &'bridge self,
        allocator: &'alloc mut crate::alloc::Allocator,
    ) -> Option<Attachment<'alloc, 'bridge>> {
        match self.raw_attach(allocator) {
            None => None,
            Some(()) => Some(Attachment {
                allocator: allocator,
                bridge: self,
            }),
        }
    }
}

impl<'alloc, 'bridge> Drop for Attachment<'alloc, 'bridge> {
    fn drop(&mut self) {
        unsafe {
            self.bridge.raw_detach(self.allocator);
        }
    }
}

// This implements GlobalAlloc for our bridge. This trait is used by the rust
// ecosystem to serve global memory allocations. For this to work, you must
// have a bridge as static variable annotated as `#[global_allocator]`.
//
// We simply forward all allocation requests to the attached allocator. If the
// allocator is NULL, we fail the allocations.
//
// Note that the bridge interface must guarantee that an attachment survives
// all allocations. That is, you must drop/deallocate all memory before
// dropping your attachment. See the description of the bridge interface for
// details.
unsafe impl core::alloc::GlobalAlloc for Bridge {
    unsafe fn alloc(&self, layout: core::alloc::Layout) -> *mut u8 {
        let allocator = self.attachment.load(atomic::Ordering::Acquire);

        if allocator.is_null() {
            return core::ptr::null_mut();
        }

        (&*allocator).alloc(layout)
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: core::alloc::Layout) {
        let allocator = self.attachment.load(atomic::Ordering::Acquire);

        assert!(!allocator.is_null());

        (&*allocator).dealloc(ptr, layout)
    }
}
