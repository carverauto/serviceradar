#![allow(non_upper_case_globals, non_camel_case_types)]

use core_foundation as cf;

pub type FSEventStreamRef = *mut ::std::os::raw::c_void;

pub type FSEventStreamCallback = extern "C" fn(
    FSEventStreamRef,            //ConstFSEventStreamRef streamRef
    *mut ::std::os::raw::c_void, // void *clientCallBackInfo
    usize,                       // size_t numEvents
    *mut ::std::os::raw::c_void, // void *eventPaths
    *mut ::std::os::raw::c_void, // const FSEventStreamEventFlags eventFlags[]
    *mut ::std::os::raw::c_void, // const FSEventStreamEventId eventIds[]
);

pub type FSEventStreamEventId = u64;

pub const kFSEventStreamEventIdSinceNow: FSEventStreamEventId = 0xFFFFFFFFFFFFFFFF;

pub type FSEventStreamCreateFlags = u32;

pub const kFSEventStreamCreateFlagNone: FSEventStreamCreateFlags = 0x00000000;
pub const kFSEventStreamCreateFlagUseCFTypes: FSEventStreamCreateFlags = 0x00000001;
pub const kFSEventStreamCreateFlagNoDefer: FSEventStreamCreateFlags = 0x00000002;
pub const kFSEventStreamCreateFlagWatchRoot: FSEventStreamCreateFlags = 0x00000004;
pub const kFSEventStreamCreateFlagIgnoreSelf: FSEventStreamCreateFlags = 0x00000008;
pub const kFSEventStreamCreateFlagFileEvents: FSEventStreamCreateFlags = 0x00000010;
pub const kFSEventStreamCreateFlagMarkSelf: FSEventStreamCreateFlags = 0x00000020;
pub const kFSEventStreamCreateFlagUseExtendedData: FSEventStreamCreateFlags = 0x00000040;

pub type FSEventStreamEventFlags = u32;

pub const kFSEventStreamEventFlagNone: FSEventStreamEventFlags = 0x00000000;
pub const kFSEventStreamEventFlagMustScanSubDirs: FSEventStreamEventFlags = 0x00000001;
pub const kFSEventStreamEventFlagUserDropped: FSEventStreamEventFlags = 0x00000002;
pub const kFSEventStreamEventFlagKernelDropped: FSEventStreamEventFlags = 0x00000004;
pub const kFSEventStreamEventFlagEventIdsWrapped: FSEventStreamEventFlags = 0x00000008;
pub const kFSEventStreamEventFlagHistoryDone: FSEventStreamEventFlags = 0x00000010;
pub const kFSEventStreamEventFlagRootChanged: FSEventStreamEventFlags = 0x00000020;
pub const kFSEventStreamEventFlagMount: FSEventStreamEventFlags = 0x00000040;
pub const kFSEventStreamEventFlagUnmount: FSEventStreamEventFlags = 0x00000080;
pub const kFSEventStreamEventFlagItemCreated: FSEventStreamEventFlags = 0x00000100;
pub const kFSEventStreamEventFlagItemRemoved: FSEventStreamEventFlags = 0x00000200;
pub const kFSEventStreamEventFlagItemInodeMetaMod: FSEventStreamEventFlags = 0x00000400;
pub const kFSEventStreamEventFlagItemRenamed: FSEventStreamEventFlags = 0x00000800;
pub const kFSEventStreamEventFlagItemModified: FSEventStreamEventFlags = 0x00001000;
pub const kFSEventStreamEventFlagItemFinderInfoMod: FSEventStreamEventFlags = 0x00002000;
pub const kFSEventStreamEventFlagItemChangeOwner: FSEventStreamEventFlags = 0x00004000;
pub const kFSEventStreamEventFlagItemXattrMod: FSEventStreamEventFlags = 0x00008000;
pub const kFSEventStreamEventFlagItemIsFile: FSEventStreamEventFlags = 0x00010000;
pub const kFSEventStreamEventFlagItemIsDir: FSEventStreamEventFlags = 0x00020000;
pub const kFSEventStreamEventFlagItemIsSymlink: FSEventStreamEventFlags = 0x00040000;
pub const kFSEventStreamEventFlagOwnEvent: FSEventStreamEventFlags = 0x00080000;
pub const kFSEventStreamEventFlagItemIsHardlink: FSEventStreamEventFlags = 0x00100000;
pub const kFSEventStreamEventFlagItemIsLastHardlink: FSEventStreamEventFlags = 0x00200000;
pub const kFSEventStreamEventFlagItemCloned: FSEventStreamEventFlags = 0x00400000;

#[repr(C)]
pub struct FSEventStreamContext {
    pub version: cf::CFIndex,
    pub info: *mut ::std::os::raw::c_void,
    pub retain: *mut ::std::os::raw::c_void,
    pub copy_description: *mut ::std::os::raw::c_void,
}
// impl Clone for FSEventStreamContext { }
// impl Copy for FSEventStreamContext { }

#[link(name = "CoreServices", kind = "framework")]
extern "C" {

    pub fn FSEventStreamCreate(
        allocator: cf::CFRef,
        callback: *const FSEventStreamCallback,
        context: *const FSEventStreamContext,
        pathsToWatch: cf::CFMutableArrayRef,
        sinceWhen: FSEventStreamEventId,
        latency: cf::CFTimeInterval,
        flags: FSEventStreamCreateFlags,
    ) -> FSEventStreamRef;

    pub fn FSEventStreamShow(stream_ref: FSEventStreamRef);
    pub fn FSEventStreamScheduleWithRunLoop(
        stream_ref: FSEventStreamRef,
        run_loop: cf::CFRunLoopRef,
        run_loop_mode: cf::CFStringRef,
    );

    pub fn FSEventStreamUnscheduleFromRunLoop(
        stream_ref: FSEventStreamRef,
        run_loop: cf::CFRunLoopRef,
        run_loop_mode: cf::CFStringRef,
    );

    pub fn FSEventStreamStart(stream_ref: FSEventStreamRef) -> bool;
    pub fn FSEventStreamFlushSync(stream_ref: FSEventStreamRef);
    pub fn FSEventStreamStop(stream_ref: FSEventStreamRef);
    pub fn FSEventStreamInvalidate(stream_ref: FSEventStreamRef);
    pub fn FSEventStreamRelease(stream_ref: FSEventStreamRef);

}
