#![allow(non_upper_case_globals, non_camel_case_types)]

extern crate libc;

use std::ffi::CString;
use std::ptr;
use std::str;

pub type CFRef = *mut ::std::os::raw::c_void;

pub type CFIndex = ::std::os::raw::c_long;
pub type CFTimeInterval = f64;

#[doc(hidden)]
pub enum CFError {}

pub type CFMutableArrayRef = CFRef;
pub type CFURLRef = CFRef;
pub type CFErrorRef = *mut CFError;
pub type CFStringRef = CFRef;
pub type CFRunLoopRef = CFRef;

pub const NULL: CFRef = 0 as CFRef;
pub const NULL_REF_PTR: *mut CFRef = 0 as *mut CFRef;

pub type CFURLPathStyle = ::std::os::raw::c_uint;

pub const kCFAllocatorDefault: CFRef = NULL;
pub const kCFURLPOSIXPathStyle: CFURLPathStyle = 0;
pub const kCFURLHFSPathStyle: CFURLPathStyle = 1;
pub const kCFURLWindowsPathStyle: CFURLPathStyle = 2;

pub const kCFStringEncodingUTF8: u32 = 0x08000100;
pub type CFStringEncoding = u32;

pub const kCFCompareEqualTo: i32 = 0;
pub type CFComparisonResult = i32;

// MacOS uses Case Insensitive path
pub const kCFCompareCaseInsensitive: u32 = 1;
pub type CFStringCompareFlags = u32;

// CFStringEncoding
pub type kCFStringEncoding = u32;
pub const UTF8: kCFStringEncoding = 0x08000100;

#[repr(C)]
pub struct CFArrayCallBacks {
    version: CFIndex,
    retain: CFRef,
    release: CFRef,
    cp: CFRef,
    equal: CFRef,
}
//impl Clone for CFArrayCallBacks { }

#[link(name = "CoreServices", kind = "framework")]
extern "C" {
    pub static kCFTypeArrayCallBacks: CFArrayCallBacks;
    pub static kCFRunLoopDefaultMode: CFStringRef;

    pub fn CFRelease(res: CFRef);
    pub fn CFShow(res: CFRef);
    pub fn CFCopyDescription(cf: CFRef) -> CFStringRef;

    pub fn CFRunLoopRun();
    pub fn CFRunLoopStop(run_loop: CFRunLoopRef);
    pub fn CFRunLoopGetCurrent() -> CFRunLoopRef;

    pub fn CFArrayCreateMutable(
        allocator: CFRef,
        capacity: CFIndex,
        callbacks: *const CFArrayCallBacks,
    ) -> CFMutableArrayRef;
    pub fn CFArrayInsertValueAtIndex(arr: CFMutableArrayRef, position: CFIndex, element: CFRef);
    pub fn CFArrayAppendValue(aff: CFMutableArrayRef, element: CFRef);
    pub fn CFArrayGetCount(arr: CFMutableArrayRef) -> CFIndex;
    pub fn CFArrayGetValueAtIndex(arr: CFMutableArrayRef, index: CFIndex) -> CFRef;

    pub fn CFURLCreateFileReferenceURL(
        allocator: CFRef,
        url: CFURLRef,
        err: *mut CFErrorRef,
    ) -> CFURLRef;
    pub fn CFURLCreateFilePathURL(
        allocator: CFRef,
        url: CFURLRef,
        err: *mut CFErrorRef,
    ) -> CFURLRef;
    pub fn CFURLCreateFromFileSystemRepresentation(
        allocator: CFRef,
        path: *const ::std::os::raw::c_char,
        len: CFIndex,
        is_directory: bool,
    ) -> CFURLRef;
    pub fn CFURLCopyAbsoluteURL(res: CFURLRef) -> CFURLRef;
    pub fn CFURLCopyLastPathComponent(res: CFURLRef) -> CFStringRef;
    pub fn CFURLCreateCopyDeletingLastPathComponent(allocator: CFRef, url: CFURLRef) -> CFURLRef;
    pub fn CFURLCreateCopyAppendingPathComponent(
        allocation: CFRef,
        url: CFURLRef,
        path: CFStringRef,
        is_directory: bool,
    ) -> CFURLRef;
    pub fn CFURLCopyFileSystemPath(anUrl: CFURLRef, path_style: CFURLPathStyle) -> CFStringRef;

    pub fn CFURLResourceIsReachable(res: CFURLRef, err: *mut CFErrorRef) -> bool;

    pub fn CFShowStr(str: CFStringRef);
    pub fn CFStringGetCString(
        theString: CFStringRef,
        buffer: *mut ::std::os::raw::c_char,
        buffer_size: CFIndex,
        encoding: CFStringEncoding,
    ) -> bool;
    pub fn CFStringGetCStringPtr(
        theString: CFStringRef,
        encoding: CFStringEncoding,
    ) -> *const ::std::os::raw::c_char;
    pub fn CFStringCreateWithCString(
        alloc: CFRef,
        source: *const ::std::os::raw::c_char,
        encoding: kCFStringEncoding,
    ) -> CFStringRef;

    pub fn CFStringCompare(
        theString1: CFStringRef,
        theString2: CFStringRef,
        compareOptions: CFStringCompareFlags,
    ) -> CFComparisonResult;
    pub fn CFArrayRemoveValueAtIndex(theArray: CFMutableArrayRef, idx: CFIndex);

}

pub unsafe fn str_path_to_cfstring_ref(source: &str, err: &mut CFErrorRef) -> CFStringRef {
    let c_path = CString::new(source).unwrap();
    let c_len = libc::strlen(c_path.as_ptr());
    let mut url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        c_path.as_ptr(),
        c_len as CFIndex,
        false,
    );
    let mut placeholder = CFURLCopyAbsoluteURL(url);
    CFRelease(url);

    let imaginary: CFRef = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);

    while !CFURLResourceIsReachable(placeholder, ptr::null_mut()) {
        let child = CFURLCopyLastPathComponent(placeholder);
        CFArrayInsertValueAtIndex(imaginary, 0, child);
        CFRelease(child);

        url = CFURLCreateCopyDeletingLastPathComponent(kCFAllocatorDefault, placeholder);
        CFRelease(placeholder);
        placeholder = url;
    }

    url = CFURLCreateFileReferenceURL(kCFAllocatorDefault, placeholder, err);
    if !err.is_null() {
        return ptr::null_mut();
    }

    CFRelease(placeholder);
    placeholder = CFURLCreateFilePathURL(kCFAllocatorDefault, url, err);
    if !err.is_null() {
        return ptr::null_mut();
    }

    CFRelease(url);

    if imaginary != kCFAllocatorDefault {
        let mut count = 0;
        while count < CFArrayGetCount(imaginary) {
            let component = CFArrayGetValueAtIndex(imaginary, count);
            url = CFURLCreateCopyAppendingPathComponent(
                kCFAllocatorDefault,
                placeholder,
                component,
                false,
            );
            CFRelease(placeholder);
            placeholder = url;
            count += 1;
        }
        CFRelease(imaginary);
    }

    let cf_path = CFURLCopyFileSystemPath(placeholder, kCFURLPOSIXPathStyle);
    CFRelease(placeholder);
    cf_path
}
