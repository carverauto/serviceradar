// Example: Hello World!
//
// This example extends the Hello-World example from the `r-efi` crate. The
// main entry-point now installs a global rust allocator and calls into the
// `efi_run()` function. The latter then prints the string "Hello World!\n" to
// console-out, waits for any key-input, and returns.
//
// Unlike the original example, here we make use of the global allocator by
// using the types from rust's `alloc::*` crate. These needs dynamic
// allocations, and we can now serve them by providing the allocator from
// `r-efi-alloc`.
//
// To integrate the allocator with rust, we need to provide a global variable
// annotated as `#[global_allocator]`. It must implement the `GlobalAlloc`
// trait. We use the `Bridge` type from our crate to serve this.

#![no_main]
#![no_std]

extern crate alloc;

use alloc::string::String;
use alloc::vec::Vec;
use r_efi::efi;

#[global_allocator]
static GLOBAL_ALLOCATOR: r_efi_alloc::global::Bridge = r_efi_alloc::global::Bridge::new();

#[panic_handler]
fn rust_panic_handler(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

// This is the wrapped entry-point of this Hello-World UEFI Application. The
// caller provides us with an extended environment, by guaranteeing us a global
// rust allocator. Hence, we can now make use of all the `alloc::*` objects.
//
// Similar to the Hello-World example from `r-efi`, this example just prints
// "Hello World!\n" to standard-output, waits for any key input, then exits.
//
// With `alloc::*` to our disposal, we use normal rust strings, and convert
// them to UTF-16 vectors before passing them to UEFI.
pub fn efi_run(_h: efi::Handle, st: *mut efi::SystemTable) -> efi::Status {
    let s: String;
    let mut v: Vec<u16>;

    // Create string and convert to UTF-16. We need a terminating NUL, since
    // UEFI uses C-String style wide-strings.
    s = String::from("Hello World!\n");
    v = s.encode_utf16().collect();
    v.push(0);

    // Print the string on console-out.
    let r =
        unsafe { ((*(*st).con_out).output_string)((*st).con_out, v.as_mut_slice().as_mut_ptr()) };
    if r.is_error() {
        return r;
    }

    // Wait for key input, by waiting on the `wait_for_key` event hook.
    let r = unsafe {
        let mut x: usize = 0;
        ((*(*st).boot_services).wait_for_event)(1, &mut (*(*st).con_in).wait_for_key, &mut x)
    };
    if r.is_error() {
        return r;
    }

    efi::Status::SUCCESS
}

// This is the main UEFI entry point, called by the UEFI environment when the
// application is spawned. We use it to create an allocator and attach it to
// the global allocator bridge. Then we invoke the `efi_run()` function as if
// it was the main entry-point. Since the attachment is dropped after
// `efi_run()` returns, the allocator is available throughout the entire
// runtime.
//
// Note that both calls here require unsafe code:
//
//  * Allocator::from_system_table(): We must guarantee `SystemTable` survives
//        longer than the allocator object we create. This is trivially true
//        here, since we pass in the system-table from the UEFI core, which is
//        guaranteed to outlive us. However, we must make sure not to call
//        ExitBootServices() and friends, obviously.
//
//  * Bridge::attach(): This function is unsafe, since it requires the caller
//        to guarantee that all memory allocations are released before it is
//        detached. Since we do not perform allocations ourselves here, we know
//        that they must be released before `efi_run()` returns. Hence, we are
//        safe as well.
//
// Lastly, we use the `LoaderData` annotation for all memory allocations.
// Depending on your UEFI application type you might want different allocators
// for different operations. The rust global allocator is a fixed type, so you
// need to use custom-allocators for all allocations that need to be put in
// different memory regions.
#[no_mangle]
pub extern "C" fn efi_main(h: efi::Handle, st: *mut efi::SystemTable) -> efi::Status {
    unsafe {
        let mut allocator = r_efi_alloc::alloc::Allocator::from_system_table(st, efi::LOADER_DATA);
        let _attachment = GLOBAL_ALLOCATOR.attach(&mut allocator);

        efi_run(h, st)
    }
}
