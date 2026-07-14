#![deny(trivial_numeric_casts, unstable_features, unused_import_braces, unused_qualifications)]
#![cfg_attr(feature = "cargo-clippy", allow(unreadable_literal))]

#[macro_use]
extern crate bitflags;

extern crate fsevent_sys as fsevent;

use fsevent::core_foundation as cf;
use fsevent as fs;

use std::convert::AsRef;
use std::ffi::CStr;
use std::ptr;
use std::slice;
use std::slice::from_raw_parts_mut;
use std::str::from_utf8;

use std::sync::mpsc::Sender;

#[cfg(target_pointer_width = "64")]
type SafePointer = u64;

#[cfg(target_pointer_width = "32")]
type SafePointer = u32;

#[derive(Clone, Copy, Debug)]
pub struct FsEventRefWrapper {
    ptr: SafePointer,
}

impl From<*mut ::std::os::raw::c_void> for FsEventRefWrapper {
    fn from(raw: *mut ::std::os::raw::c_void) -> FsEventRefWrapper {
        let ptr = raw as SafePointer;
        Self { ptr }
    }
}

impl From<FsEventRefWrapper> for *mut ::std::os::raw::c_void {
    fn from(safe: FsEventRefWrapper) -> *mut ::std::os::raw::c_void {
        safe.ptr as *mut ::std::os::raw::c_void
    }
}

pub struct FsEvent {
    paths: Vec<String>,
    since_when: fs::FSEventStreamEventId,
    latency: cf::CFTimeInterval,
    flags: fs::FSEventStreamCreateFlags,
}

#[derive(Debug)]
pub struct Event {
    pub event_id: u64,
    pub flag: StreamFlags,
    pub path: String,
}

// Synchronize with
// /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Headers/FSEvents.h
bitflags! {
  #[repr(C)]
  pub struct StreamFlags: u32 {
    const NONE = 0x00000000;
    const MUST_SCAN_SUBDIRS = 0x00000001;
    const USER_DROPPED = 0x00000002;
    const KERNEL_DROPPED = 0x00000004;
    const IDS_WRAPPED = 0x00000008;
    const HISTORY_DONE = 0x00000010;
    const ROOT_CHANGED = 0x00000020;
    const MOUNT = 0x00000040;
    const UNMOUNT = 0x00000080;
    const ITEM_CREATED = 0x00000100;
    const ITEM_REMOVED = 0x00000200;
    const INOTE_META_MOD = 0x00000400;
    const ITEM_RENAMED = 0x00000800;
    const ITEM_MODIFIED = 0x00001000;
    const FINDER_INFO_MOD = 0x00002000;
    const ITEM_CHANGE_OWNER = 0x00004000;
    const ITEM_XATTR_MOD = 0x00008000;
    const IS_FILE = 0x00010000;
    const IS_DIR = 0x00020000;
    const IS_SYMLIMK = 0x00040000;
    const OWN_EVENT = 0x00080000;
    const IS_HARDLINK = 0x00100000;
    const IS_LAST_HARDLINK = 0x00200000;
    const ITEM_CLONED = 0x400000;
  }
}

impl std::fmt::Display for StreamFlags {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        if self.contains(StreamFlags::MUST_SCAN_SUBDIRS) {
            let _d = write!(f, "MUST_SCAN_SUBDIRS ");
        }
        if self.contains(StreamFlags::USER_DROPPED) {
            let _d = write!(f, "USER_DROPPED ");
        }
        if self.contains(StreamFlags::KERNEL_DROPPED) {
            let _d = write!(f, "KERNEL_DROPPED ");
        }
        if self.contains(StreamFlags::IDS_WRAPPED) {
            let _d = write!(f, "IDS_WRAPPED ");
        }
        if self.contains(StreamFlags::HISTORY_DONE) {
            let _d = write!(f, "HISTORY_DONE ");
        }
        if self.contains(StreamFlags::ROOT_CHANGED) {
            let _d = write!(f, "ROOT_CHANGED ");
        }
        if self.contains(StreamFlags::MOUNT) {
            let _d = write!(f, "MOUNT ");
        }
        if self.contains(StreamFlags::UNMOUNT) {
            let _d = write!(f, "UNMOUNT ");
        }
        if self.contains(StreamFlags::ITEM_CREATED) {
            let _d = write!(f, "ITEM_CREATED ");
        }
        if self.contains(StreamFlags::ITEM_REMOVED) {
            let _d = write!(f, "ITEM_REMOVED ");
        }
        if self.contains(StreamFlags::INOTE_META_MOD) {
            let _d = write!(f, "INOTE_META_MOD ");
        }
        if self.contains(StreamFlags::ITEM_RENAMED) {
            let _d = write!(f, "ITEM_RENAMED ");
        }
        if self.contains(StreamFlags::ITEM_MODIFIED) {
            let _d = write!(f, "ITEM_MODIFIED ");
        }
        if self.contains(StreamFlags::FINDER_INFO_MOD) {
            let _d = write!(f, "FINDER_INFO_MOD ");
        }
        if self.contains(StreamFlags::ITEM_CHANGE_OWNER) {
            let _d = write!(f, "ITEM_CHANGE_OWNER ");
        }
        if self.contains(StreamFlags::ITEM_XATTR_MOD) {
            let _d = write!(f, "ITEM_XATTR_MOD ");
        }
        if self.contains(StreamFlags::IS_FILE) {
            let _d = write!(f, "IS_FILE ");
        }
        if self.contains(StreamFlags::IS_DIR) {
            let _d = write!(f, "IS_DIR ");
        }
        if self.contains(StreamFlags::IS_SYMLIMK) {
            let _d = write!(f, "IS_SYMLIMK ");
        }
        if self.contains(StreamFlags::OWN_EVENT) {
            let _d = write!(f, "OWN_EVENT ");
        }
        if self.contains(StreamFlags::IS_LAST_HARDLINK) {
            let _d = write!(f, "IS_LAST_HARDLINK ");
        }
        if self.contains(StreamFlags::IS_HARDLINK) {
            let _d = write!(f, "IS_HARDLINK ");
        }
        if self.contains(StreamFlags::ITEM_CLONED) {
            let _d = write!(f, "ITEM_CLONED ");
        }
        write!(f, "")
    }
}

fn default_stream_context(event_sender: *const Sender<Event>) -> fs::FSEventStreamContext {
    let ptr = event_sender as *mut ::std::os::raw::c_void;
    fs::FSEventStreamContext {
        version: 0,
        info: ptr,
        retain: cf::NULL,
        copy_description: cf::NULL,
    }
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug)]
pub struct Error {
    msg: String,
}

impl std::error::Error for Error {
    fn description(&self) -> &str {
        &self.msg
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        self.msg.fmt(f)
    }
}

impl From<std::sync::mpsc::RecvTimeoutError> for Error {
    fn from(err: std::sync::mpsc::RecvTimeoutError) -> Error {
        use std::error::Error;

        Self {
            msg: err.description().to_string(),
        }
    }
}

impl FsEvent {
    pub fn new(paths: Vec<String>) -> Self {
        Self {
            paths,
            since_when: fs::kFSEventStreamEventIdSinceNow,
            latency: 0.0,
            flags: fs::kFSEventStreamCreateFlagFileEvents | fs::kFSEventStreamCreateFlagNoDefer,
        }
    }

    // https://github.com/thibaudgg/rb-fsevent/blob/master/ext/fsevent_watch/main.c
    pub fn append_path(&mut self, source: &str) -> Result<()> {
        self.paths.push(source.to_string());
        Ok(())
    }

    fn build_native_paths(&self) -> Result<cf::CFMutableArrayRef> {
        let native_paths = unsafe {
            cf::CFArrayCreateMutable(cf::kCFAllocatorDefault, 0, &cf::kCFTypeArrayCallBacks)
        };

        if native_paths == std::ptr::null_mut() {
            Err(Error {
                msg: "Unable to allocate CFMutableArrayRef".to_string(),
            })
        } else {
            for path in &self.paths {
                unsafe {
                    let mut err = ptr::null_mut();
                    let cf_path = cf::str_path_to_cfstring_ref(path, &mut err);
                    if !err.is_null() {
                        let cf_str = cf::CFCopyDescription(err as cf::CFRef);
                        let mut buf = [0; 1024];
                        cf::CFStringGetCString(
                            cf_str,
                            buf.as_mut_ptr(),
                            buf.len() as cf::CFIndex,
                            cf::kCFStringEncodingUTF8,
                        );
                        return Err(Error {
                            msg: CStr::from_ptr(buf.as_ptr())
                                .to_str()
                                .unwrap_or("Unknown error")
                                .to_string(),
                        });
                    } else {
                        cf::CFArrayAppendValue(native_paths, cf_path);
                        cf::CFRelease(cf_path);
                    }
                }
            }

            Ok(native_paths)
        }
    }

    fn internal_observe(
        since_when: fs::FSEventStreamEventId,
        latency: cf::CFTimeInterval,
        flags: fs::FSEventStreamCreateFlags,
        paths: FsEventRefWrapper,
        event_sender: Sender<Event>,
        subscription_handle_sender: Option<Sender<FsEventRefWrapper>>,
    ) -> Result<()> {
        let stream_context = default_stream_context(&event_sender);
        let cb = callback as *mut _;
        let paths = paths.into();

        unsafe {
            let stream = fs::FSEventStreamCreate(
                cf::kCFAllocatorDefault,
                cb,
                &stream_context,
                paths,
                since_when,
                latency,
                flags,
            );

            // fs::FSEventStreamShow(stream);

            match subscription_handle_sender {
                Some(ret_tx) => {
                    let runloop_ref = cf::CFRunLoopGetCurrent();
                    let runloop_ref_safe = FsEventRefWrapper::from(runloop_ref);
                    let ptr_val = runloop_ref_safe.ptr.clone();
                    ret_tx
                        .send(runloop_ref_safe)
                        .expect(&format!("Unable to return CFRunLoopRef ({:#X})", ptr_val));
                }
                None => {}
            }

            fs::FSEventStreamScheduleWithRunLoop(
                stream,
                cf::CFRunLoopGetCurrent(),
                cf::kCFRunLoopDefaultMode,
            );

            fs::FSEventStreamStart(stream);
            cf::CFRunLoopRun();

            fs::FSEventStreamFlushSync(stream);
            fs::FSEventStreamStop(stream);
        }

        Ok(())
    }

    pub fn observe(&self, event_sender: Sender<Event>) {
        let native_paths = self.build_native_paths()
            .expect("Unable to build CFMutableArrayRef of watched paths.");
        let safe_native_paths = FsEventRefWrapper::from(native_paths);
        Self::internal_observe(
            self.since_when,
            self.latency,
            self.flags,
            safe_native_paths,
            event_sender,
            None,
        ).unwrap();
    }

    pub fn observe_async(&self, event_sender: Sender<Event>) -> Result<FsEventRefWrapper> {
        let (ret_tx, ret_rx) = std::sync::mpsc::channel();
        let native_paths = self.build_native_paths()?;
        let safe_native_paths = FsEventRefWrapper::from(native_paths);

        let since_when = self.since_when;
        let latency = self.latency;
        let flags = self.flags;
        std::thread::spawn(move || {
            Self::internal_observe(
                since_when,
                latency,
                flags,
                safe_native_paths,
                event_sender,
                Some(ret_tx),
            )
        });

        match ret_rx.recv_timeout(std::time::Duration::from_secs(5)) {
            Ok(v) => Ok(v),
            Err(e) => Err(Error::from(e)),
        }
    }

    pub fn shutdown_observe(&self, handle: FsEventRefWrapper) {
        unsafe { cf::CFRunLoopStop(handle.into()) };
    }
}

#[allow(unused_variables)]
unsafe fn callback(
    stream_ref: fs::FSEventStreamRef,
    info: *mut ::std::os::raw::c_void,
    num_events: usize,                                 // size_t numEvents
    event_paths: *const *const ::std::os::raw::c_char, // void *eventPaths
    event_flags: *mut ::std::os::raw::c_void,          // const FSEventStreamEventFlags eventFlags[]
    event_ids: *mut ::std::os::raw::c_void,            // const FSEventStreamEventId eventIds[]
) {
    let num = num_events;
    let e_ptr = event_flags as *mut u32;
    let i_ptr = event_ids as *mut u64;
    let sender = info as *mut Sender<Event>;

    let paths: &[*const ::std::os::raw::c_char] =
        std::mem::transmute(slice::from_raw_parts(event_paths, num));
    let flags = from_raw_parts_mut(e_ptr, num);
    let ids = from_raw_parts_mut(i_ptr, num);

    for p in 0..num {
        let i = CStr::from_ptr(paths[p]).to_bytes();
        let path = from_utf8(i).expect("Invalid UTF8 string.");
        let flag: StreamFlags = StreamFlags::from_bits(flags[p])
            .expect(format!("Unable to decode StreamFlags: {} for {}", flags[p], path).as_ref());
        // println!("{}: {}", ids[p], flag);

        let event = Event {
            event_id: ids[p],
            flag,
            path: path.to_string(),
        };
        let _s = (*sender).send(event);
    }
}
