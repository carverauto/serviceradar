//! Raw Allocator
//!
//! This module exposes the raw handlers behind the UEFI allocator. The
//! allocator traits of the standard library are marked as unstable, hence this
//! module provides stable access to the same functionality, if required.
//!
//! Use of the raw allocator is only recommended if the other exposes APIs are
//! not an option.

use r_efi::efi;

// UEFI guarantees 8-byte alignments through `AllocatePool()`. Any request
// higher than this alignment needs to take special precautions to align the
// returned pointer, and revert that step when freeing the memory block again.
const POOL_ALIGNMENT: usize = 8usize;

// Alignment Marker
//
// Since UEFI has no functions to allocate blocks of arbitrary alignment, we
// have to work around this. We extend the allocation size by the required
// alignment and then offset the pointer before returning it. This will
// properly align the pointer to the given request.
//
// However, when freeing memory again, we have to somehow get back the original
// pointer. Therefore, we store the original address directly in front of the
// memory block that we just aligned. When freeing memory, we simply retrieve
// this marker and free the original address.
#[repr(C)]
struct Marker(*mut u8);

fn align_request(size: usize, align: usize) -> usize {
    // If the alignment request is within UEFI guarantees, there is no need to
    // adjust the size request. In all other cases, we might have to align the
    // allocated memory block. Hence, we increment the request size by the
    // alignment size. Strictly speaking, we only need `align - POOL_ALIGNMENT`
    // as additional space, since the pool alignment is always guaranteed by
    // UEFI. However, by adding the full alignment we are guaranteed
    // `POOL_ALIGNMENT` extra space. This extra space is used to store a marker
    // so we can retrieve the original pointer when freeing the memory space.
    if align > POOL_ALIGNMENT {
        size + align
    } else {
        size
    }
}

unsafe fn align_block(ptr: *mut u8, align: usize) -> *mut u8 {
    // This function takes a pointer returned by the pool-allocator, and aligns
    // it to the requested alignment. If this alignment is smaller than the
    // guaranteed pool alignment, there is nothing to be done. If it is bigger,
    // we will have to offset the pointer. We rely on the caller using
    // `align_request()` to increase the allocation size beforehand. We then
    // store the original address as `Marker` in front of the aligned pointer,
    // so `unalign_block()` can retrieve it again.
    if align > POOL_ALIGNMENT {
        // In `align_request()` we guarantee the allocation size includes an
        // additional `align` bytes. Since the pool allocation already
        // guaranteed an alignment of `POOL_ALIGNMENT`, we know that
        // `offset >= POOL_ALIGNMENT` here. We then verify that
        // `POOL_ALIGNMENT` serves the needs of our `Marker` object. Note that
        // all but the first assertion are constant expressions, so the
        // compiler will optimize them away.
        let offset = align - (ptr as usize & (align - 1));
        assert!(offset >= POOL_ALIGNMENT);
        assert!(POOL_ALIGNMENT >= core::mem::size_of::<Marker>());
        assert!(POOL_ALIGNMENT >= core::mem::align_of::<Marker>());

        // We calculated the alignment-offset, so adjust the pointer and store
        // the original address directly in front. This will allow
        // `unalign_block()` to retrieve the original address, so it can free
        // the entire memory block.
        let aligned = ptr.add(offset);
        core::ptr::write((aligned as *mut Marker).offset(-1), Marker(ptr));
        aligned
    } else {
        ptr
    }
}

unsafe fn unalign_block(ptr: *mut u8, align: usize) -> *mut u8 {
    // This undoes what `align_block()` did. That is, we retrieve the original
    // address that was stored directly in front of the aligned block, and
    // return it to the caller. Note that this is only the case if the
    // alignment exceeded the guaranteed alignment of the allocator.
    if align > POOL_ALIGNMENT {
        core::ptr::read((ptr as *mut Marker).offset(-1)).0
    } else {
        ptr
    }
}

/// Allocate Memory from UEFI Boot-Services
///
/// Use the UEFI `allocate_pool` boot-services to request a block of memory
/// satisfying the given memory layout. The `memory_type` parameter specifies
/// which UEFI allocator to use.
///
/// This returns a null-pointer if the allocator could not serve the request
/// (which on UEFI implies out-of-memory). Otherwise, a non-null pointer to
/// the aligned block is returned.
///
/// Safety
/// ------
///
/// To ensure safety of this interface, the caller must guarantee:
///
///  * The allocation size must not be 0. The function will panic otherwise.
///
///  * It must be safe for this function to call `allocate_pool` of the
///    boot-services provided via the system-table. It is the responsibility of
///    the caller to retain boot-services until the returned allocation is
///    released via `dealloc()`, or to account for it otherwise.
///
///  * The returned pointer is not necessarily the same pointer as returned
///    by `allocate_pool` of the boot-services. A caller must not assume this
///    when forwarding the pointer to other allocation services.
pub unsafe fn alloc(
    system_table: *mut efi::SystemTable,
    layout: core::alloc::Layout,
    memory_type: efi::MemoryType,
) -> *mut u8 {
    // `Layout` guarantees the size+align combination does not overflow.
    let align = layout.align();
    let size = layout.size();

    // Verify our increased requirements are met.
    assert!(size > 0);

    // We need extra allocation space to guarantee large alignment requests. If
    // `size+align` overflows, there will be insufficient address-space for the
    // request, so make it fail early.
    if size.checked_add(align).is_none() {
        return core::ptr::null_mut();
    }

    // We forward the allocation request to `AllocatePool()`. This takes the
    // memory-type and size as argument, and places a pointer to the allocation
    // in an output argument. Note that UEFI guarantees 8-byte alignment (i.e.,
    // `POOL_ALIGNMENT`). To support higher alignments, see the
    // `align_request() / align_block() / unalign_block()` helpers.
    let mut ptr: *mut core::ffi::c_void = core::ptr::null_mut();
    let size_allocated = align_request(size, align);
    let r = unsafe {
        ((*(*system_table).boot_services).allocate_pool)(
            memory_type,
            size_allocated,
            &mut ptr,
        )
    };

    // The only real error-scenario is OOM ("out-of-memory"). UEFI does not
    // clearly specify what a return value of NULL+success means (but indicates
    // in a lot of cases that NULL is never a valid pointer). Furthermore,
    // since the 0-page is usually unmapped and not available for
    // EFI_CONVENTIONAL_MEMORY, a NULL pointer cannot be a valid return
    // pointer. Therefore, we treat both a function failure as well as a NULL
    // pointer the same.
    // No known UEFI implementation returns `NULL`, hence this is mostly a
    // safety net in case any unknown implementation fails to adhere.
    if r.is_error() || ptr.is_null() {
        core::ptr::null_mut()
    } else {
        unsafe { align_block(ptr as *mut u8, align) }
    }
}

/// Deallocate Memory from UEFI Boot-Services
///
/// Use the UEFI `free_pool` boot-services to release a block of memory
/// previously allocated through `alloc()`.
///
/// Safety
/// ------
///
/// The memory block must be the same as previously returned by `alloc()`.
/// Furthermore, this function must be able to call the UEFI boot-servies
/// through the specified system table, and this must match the same
/// boot-services the memory block was allocated through.
///
/// The passed layout must match the layout used to allocate the memory block.
pub unsafe fn dealloc(
    system_table: *mut efi::SystemTable,
    ptr: *mut u8,
    layout: core::alloc::Layout,
) {
    // UEFI never allows null-pointers for allocations, hence such a pointer
    // cannot have been retrieved through `alloc()` previously.
    assert!(!ptr.is_null());

    // Un-align the pointer to get access to the actual start of the block.
    let original = unalign_block(
        ptr,
        layout.align(),
    ) as *mut core::ffi::c_void;

    // Release the memory block via the boot-services.
    let r = ((*(*system_table).boot_services).free_pool)(original);

    // The spec allows returning errors from `FreePool()`. However, it
    // must serve any valid requests. Only `INVALID_PARAMETER` is
    // listed as possible error. Hence, there is no point in forwarding
    // the return value. We still assert on it to improve diagnostics
    // in early-boot situations. This should be a negligible
    // performance penalty.
    assert!(!r.is_error());
}

#[cfg(test)]
mod tests {
    use super::*;

    // Test the `align_request()` helper and verify that it correctly
    // calculates the supported alignment requests.
    #[test]
    fn align() {
        let ptrsize = std::mem::size_of::<*mut ()>();

        // UEFI ABI specifies that allocation alignment minimum is always 8. So
        // this can be statically verified.
        assert_eq!(POOL_ALIGNMENT, 8);

        // Loop over allocation-request sizes from 0-256 and alignments from
        // 1-128, and verify that in case of overalignment there is at least
        // space for one additional pointer to store in the allocation.
        for i in 0..256 {
            for j in &[1, 2, 4, 8, 16, 32, 64, 128] {
                if *j <= 8 {
                    assert_eq!(align_request(i, *j), i);
                } else {
                    assert!(align_request(i, *j) > i + ptrsize);
                }
            }
        }
    }
}
