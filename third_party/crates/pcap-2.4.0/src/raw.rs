// GRCOV_EXCL_START
#![allow(dead_code)]
#![allow(non_camel_case_types)]

use libc::{c_char, c_int, c_uchar, c_uint, c_ushort, sockaddr, timeval, FILE};

#[cfg(test)]
use mockall::automock;

pub const PCAP_IF_LOOPBACK: u32 = 0x00000001;
pub const PCAP_IF_UP: u32 = 0x00000002;
pub const PCAP_IF_RUNNING: u32 = 0x00000004;
pub const PCAP_IF_WIRELESS: u32 = 0x00000008;
pub const PCAP_IF_CONNECTION_STATUS: u32 = 0x00000030;
pub const PCAP_IF_CONNECTION_STATUS_UNKNOWN: u32 = 0x00000000;
pub const PCAP_IF_CONNECTION_STATUS_CONNECTED: u32 = 0x00000010;
pub const PCAP_IF_CONNECTION_STATUS_DISCONNECTED: u32 = 0x00000020;
pub const PCAP_IF_CONNECTION_STATUS_NOT_APPLICABLE: u32 = 0x00000030;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct bpf_program {
    pub bf_len: c_uint,
    pub bf_insns: *mut bpf_insn,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct bpf_insn {
    pub code: c_ushort,
    pub jt: c_uchar,
    pub jf: c_uchar,
    pub k: c_uint,
}

pub enum pcap_t {}

pub enum pcap_dumper_t {}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct pcap_file_header {
    pub magic: c_uint,
    pub version_major: c_ushort,
    pub version_minor: c_ushort,
    pub thiszone: c_int,
    pub sigfigs: c_uint,
    pub snaplen: c_uint,
    pub linktype: c_uint,
}

pub type pcap_direction_t = c_uint;

pub const PCAP_D_INOUT: pcap_direction_t = 0;
pub const PCAP_D_IN: pcap_direction_t = 1;
pub const PCAP_D_OUT: pcap_direction_t = 2;

#[repr(C)]
#[derive(Copy, Clone)]
pub struct pcap_pkthdr {
    pub ts: timeval,
    pub caplen: c_uint,
    pub len: c_uint,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct pcap_stat {
    pub ps_recv: c_uint,
    pub ps_drop: c_uint,
    pub ps_ifdrop: c_uint,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct pcap_if_t {
    pub next: *mut pcap_if_t,
    pub name: *mut c_char,
    pub description: *mut c_char,
    pub addresses: *mut pcap_addr_t,
    pub flags: c_uint,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct pcap_addr_t {
    pub next: *mut pcap_addr_t,
    pub addr: *mut sockaddr,
    pub netmask: *mut sockaddr,
    pub broadaddr: *mut sockaddr,
    pub dstaddr: *mut sockaddr,
}

#[cfg(windows)]
#[repr(C)]
#[derive(Copy, Clone)]
pub struct pcap_send_queue {
    pub maxlen: c_uint,
    pub len: c_uint,
    pub buffer: *mut c_char,
}

// This is not Option<fn>, pcap functions do not check if the handler is null so it is wrong to
// pass them Option::<fn>::None.
pub type pcap_handler =
    extern "C" fn(arg1: *mut c_uchar, arg2: *const pcap_pkthdr, arg3: *const c_uchar) -> ();

#[cfg_attr(test, automock)]
pub mod ffi {
    use super::*;

    extern "C" {
        // [OBSOLETE] pub fn pcap_lookupdev(arg1: *mut c_char) -> *mut c_char;
        // pub fn pcap_lookupnet(arg1: *const c_char, arg2: *mut c_uint, arg3: *mut c_uint,
        //                       arg4: *mut c_char) -> c_int;
        pub fn pcap_create(arg1: *const c_char, arg2: *mut c_char) -> *mut pcap_t;
        pub fn pcap_set_snaplen(arg1: *mut pcap_t, arg2: c_int) -> c_int;
        pub fn pcap_set_promisc(arg1: *mut pcap_t, arg2: c_int) -> c_int;
        // pub fn pcap_can_set_rfmon(arg1: *mut pcap_t) -> c_int;
        pub fn pcap_set_timeout(arg1: *mut pcap_t, arg2: c_int) -> c_int;
        pub fn pcap_set_buffer_size(arg1: *mut pcap_t, arg2: c_int) -> c_int;
        pub fn pcap_activate(arg1: *mut pcap_t) -> c_int;
        // pub fn pcap_open_live(arg1: *const c_char, arg2: c_int, arg3: c_int, arg4: c_int,
        //                       arg5: *mut c_char) -> *mut pcap_t;
        pub fn pcap_open_dead(arg1: c_int, arg2: c_int) -> *mut pcap_t;
        pub fn pcap_open_offline(arg1: *const c_char, arg2: *mut c_char) -> *mut pcap_t;
        pub fn pcap_fopen_offline(arg1: *mut FILE, arg2: *mut c_char) -> *mut pcap_t;
        pub fn pcap_close(arg1: *mut pcap_t);
        pub fn pcap_loop(
            arg1: *mut pcap_t,
            arg2: c_int,
            arg3: pcap_handler,
            arg4: *mut c_uchar,
        ) -> c_int;
        // pub fn pcap_dispatch(arg1: *mut pcap_t, arg2: c_int, arg3: pcap_handler,
        //                      arg4: *mut c_uchar)-> c_int;
        // pub fn pcap_next(arg1: *mut pcap_t, arg2: *mut pcap_pkthdr) -> *const c_uchar;
        pub fn pcap_next_ex(
            arg1: *mut pcap_t,
            arg2: *mut *mut pcap_pkthdr,
            arg3: *mut *const c_uchar,
        ) -> c_int;
        pub fn pcap_breakloop(arg1: *mut pcap_t);
        pub fn pcap_stats(arg1: *mut pcap_t, arg2: *mut pcap_stat) -> c_int;
        pub fn pcap_setfilter(arg1: *mut pcap_t, arg2: *mut bpf_program) -> c_int;
        pub fn pcap_setdirection(arg1: *mut pcap_t, arg2: pcap_direction_t) -> c_int;
        // pub fn pcap_getnonblock(arg1: *mut pcap_t, arg2: *mut c_char) -> c_int;
        pub fn pcap_setnonblock(arg1: *mut pcap_t, arg2: c_int, arg3: *mut c_char) -> c_int;
        pub fn pcap_sendpacket(arg1: *mut pcap_t, arg2: *const c_uchar, arg3: c_int) -> c_int;
        // pub fn pcap_statustostr(arg1: c_int) -> *const c_char;
        // pub fn pcap_strerror(arg1: c_int) -> *const c_char;
        pub fn pcap_geterr(arg1: *mut pcap_t) -> *mut c_char;
        // pub fn pcap_perror(arg1: *mut pcap_t, arg2: *mut c_char);
        pub fn pcap_compile(
            arg1: *mut pcap_t,
            arg2: *mut bpf_program,
            arg3: *const c_char,
            arg4: c_int,
            arg5: c_uint,
        ) -> c_int;
        // pub fn pcap_compile_nopcap(arg1: c_int, arg2: c_int, arg3: *mut bpf_program,
        //                            arg4: *const c_char, arg5: c_int, arg6: c_uint) -> c_int;
        pub fn pcap_freecode(arg1: *mut bpf_program);
        pub fn pcap_offline_filter(
            arg1: *const bpf_program,
            arg2: *const pcap_pkthdr,
            arg3: *const c_uchar,
        ) -> c_int;
        pub fn pcap_datalink(arg1: *mut pcap_t) -> c_int;
        // pub fn pcap_datalink_ext(arg1: *mut pcap_t) -> c_int;
        pub fn pcap_list_datalinks(arg1: *mut pcap_t, arg2: *mut *mut c_int) -> c_int;
        pub fn pcap_set_datalink(arg1: *mut pcap_t, arg2: c_int) -> c_int;
        pub fn pcap_free_datalinks(arg1: *mut c_int);
        pub fn pcap_datalink_name_to_val(arg1: *const c_char) -> c_int;
        pub fn pcap_datalink_val_to_name(arg1: c_int) -> *const c_char;
        pub fn pcap_datalink_val_to_description(arg1: c_int) -> *const c_char;
        // pub fn pcap_snapshot(arg1: *mut pcap_t) -> c_int;
        // pub fn pcap_is_swapped(arg1: *mut pcap_t) -> c_int;
        pub fn pcap_major_version(arg1: *mut pcap_t) -> c_int;
        pub fn pcap_minor_version(arg1: *mut pcap_t) -> c_int;
        // pub fn pcap_file(arg1: *mut pcap_t) -> *mut FILE;
        pub fn pcap_fileno(arg1: *mut pcap_t) -> c_int;
        pub fn pcap_dump_open(arg1: *mut pcap_t, arg2: *const c_char) -> *mut pcap_dumper_t;
        pub fn pcap_dump_fopen(arg1: *mut pcap_t, fp: *mut FILE) -> *mut pcap_dumper_t;
        // pub fn pcap_dump_file(arg1: *mut pcap_dumper_t) -> *mut FILE;
        // pub fn pcap_dump_ftell(arg1: *mut pcap_dumper_t) -> c_long;
        pub fn pcap_dump_flush(arg1: *mut pcap_dumper_t) -> c_int;
        pub fn pcap_dump_close(arg1: *mut pcap_dumper_t);
        pub fn pcap_dump(arg1: *mut c_uchar, arg2: *const pcap_pkthdr, arg3: *const c_uchar);
        pub fn pcap_findalldevs(arg1: *mut *mut pcap_if_t, arg2: *mut c_char) -> c_int;
        pub fn pcap_freealldevs(arg1: *mut pcap_if_t);
        // pub fn pcap_lib_version() -> *const c_char;
        // pub fn bpf_image(arg1: *const bpf_insn, arg2: c_int) -> *mut c_char;
        // pub fn bpf_dump(arg1: *const bpf_program, arg2: c_int);
        pub fn pcap_get_selectable_fd(arg1: *mut pcap_t) -> c_int;
    }

    #[cfg(libpcap_1_2_1)]
    extern "C" {
        // pub fn pcap_free_tstamp_types(arg1: *mut c_int) -> ();
        // pub fn pcap_list_tstamp_types(arg1: *mut pcap_t, arg2: *mut *mut c_int) -> c_int;
        // pub fn pcap_tstamp_type_name_to_val(arg1: *const c_char) -> c_int;
        // pub fn pcap_tstamp_type_val_to_description(arg1: c_int) -> *const c_char;
        // pub fn pcap_tstamp_type_val_to_name(arg1: c_int) -> *const c_char;
        pub fn pcap_set_tstamp_type(arg1: *mut pcap_t, arg2: c_int) -> c_int;
    }

    #[cfg(libpcap_1_5_0)]
    extern "C" {
        pub fn pcap_fopen_offline_with_tstamp_precision(
            arg1: *mut FILE,
            arg2: c_uint,
            arg3: *mut c_char,
        ) -> *mut pcap_t;
        // pub fn pcap_get_tstamp_precision(arg1: *mut pcap_t) -> c_int;
        pub fn pcap_open_dead_with_tstamp_precision(
            arg1: c_int,
            arg2: c_int,
            arg3: c_uint,
        ) -> *mut pcap_t;
        pub fn pcap_open_offline_with_tstamp_precision(
            arg1: *const c_char,
            arg2: c_uint,
            arg3: *mut c_char,
        ) -> *mut pcap_t;
        pub fn pcap_set_immediate_mode(arg1: *mut pcap_t, arg2: c_int) -> c_int;
        pub fn pcap_set_tstamp_precision(arg1: *mut pcap_t, arg2: c_int) -> c_int;
    }

    #[cfg(libpcap_1_7_2)]
    extern "C" {
        pub fn pcap_dump_open_append(arg1: *mut pcap_t, arg2: *const c_char) -> *mut pcap_dumper_t;
    }

    #[cfg(libpcap_1_9_0)]
    extern "C" {
        // pcap_bufsize
        // pcap_createsrcstr
        // pcap_dump_ftell64
        // pcap_findalldevs_ex
        // pcap_get_required_select_timeout
        // pcap_open
        // pcap_parsesrcstr
        // pcap_remoteact_accept
        // pcap_remoteact_cleanup
        // pcap_remoteact_close
        // pcap_remoteact_list
        // pcap_set_protocol_linux
        // pcap_setsampling
    }

    #[cfg(libpcap_1_9_1)]
    extern "C" {
        // pcap_datalink_val_to_description_or_dlt
    }
}

#[cfg(not(windows))]
#[cfg_attr(test, automock)]
pub mod ffi_unix {
    use super::*;

    #[link(name = "pcap")]
    extern "C" {
        // pub fn pcap_inject(arg1: *mut pcap_t, arg2: *const c_void, arg3: size_t) -> c_int;
        pub fn pcap_set_rfmon(arg1: *mut pcap_t, arg2: c_int) -> c_int;
    }
}

#[cfg(target_os = "macos")]
#[cfg_attr(test, automock)]
pub mod ffi_macos {
    use super::*;

    #[cfg(libpcap_1_5_3)]
    extern "C" {
        pub fn pcap_set_want_pktap(arg1: *mut pcap_t, arg2: c_int) -> c_int;
    }
}

#[cfg(windows)]
#[cfg_attr(test, automock)]
pub mod ffi_windows {
    use windows_sys::Win32::Foundation::HANDLE;

    use super::*;

    pub const WINPCAP_MINTOCOPY_DEFAULT: c_int = 16000;

    #[link(name = "wpcap")]
    extern "C" {
        pub fn pcap_setmintocopy(arg1: *mut pcap_t, arg2: c_int) -> c_int;
        pub fn pcap_getevent(p: *mut pcap_t) -> HANDLE;
        pub fn pcap_sendqueue_alloc(memsize: c_uint) -> *mut pcap_send_queue;
        pub fn pcap_sendqueue_destroy(queue: *mut pcap_send_queue);
        pub fn pcap_sendqueue_queue(
            queue: *mut pcap_send_queue,
            pkt_header: *const pcap_pkthdr,
            pkt_data: *const c_uchar,
        ) -> c_int;
        pub fn pcap_sendqueue_transmit(
            p: *mut pcap_t,
            queue: *mut pcap_send_queue,
            sync: c_int,
        ) -> c_uint;
    }
}

// The conventional solution is to use `mockall_double`. However, automock's requirement for an
// inner module would require changing the imports in all the files using this module. This approach
// allows all the other modules to keep using the `raw` module as before.
#[cfg(not(test))]
pub use ffi::*;

#[cfg(not(test))]
#[cfg(not(windows))]
pub use ffi_unix::*;

#[cfg(not(test))]
#[cfg(target_os = "macos")]
pub use ffi_macos::*;

#[cfg(not(test))]
#[cfg(windows)]
pub use ffi_windows::*;

#[cfg(test)]
pub use mock_ffi::*;

#[cfg(test)]
#[cfg(not(windows))]
pub use mock_ffi_unix::*;

#[cfg(test)]
#[cfg(target_os = "macos")]
pub use mock_ffi_macos::*;

#[cfg(test)]
#[cfg(windows)]
pub use mock_ffi_windows::*;

#[cfg(test)]
pub mod testmod {
    use std::{ffi::CString, sync::Mutex};

    use once_cell::sync::Lazy;

    use super::*;

    pub struct GeterrContext(__pcap_geterr::Context);

    // Must be acquired by any test using mock FFI.
    pub static RAWMTX: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));

    pub fn as_pcap_t<T: ?Sized>(value: &mut T) -> *mut pcap_t {
        value as *mut T as *mut pcap_t
    }

    pub fn as_pcap_dumper_t<T: ?Sized>(value: &mut T) -> *mut pcap_dumper_t {
        value as *mut T as *mut pcap_dumper_t
    }

    pub fn geterr_expect(pcap: *mut pcap_t) -> GeterrContext {
        // Lock must be acquired by caller.
        assert!(RAWMTX.try_lock().is_err());

        let err = CString::new("oh oh").unwrap();
        let ctx = pcap_geterr_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap)
            .return_once_st(|_| err.into_raw());

        GeterrContext(ctx)
    }
}
// GRCOV_EXCL_STOP
