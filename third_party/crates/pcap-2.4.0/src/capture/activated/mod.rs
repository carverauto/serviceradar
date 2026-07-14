pub mod active;
pub mod dead;
pub mod iterator;
pub mod offline;

use std::{
    any::Any,
    convert::TryInto,
    ffi::CString,
    fmt, mem,
    panic::{catch_unwind, resume_unwind, AssertUnwindSafe},
    path::Path,
    ptr::{self, NonNull},
    slice,
    sync::{Arc, Weak},
};

#[cfg(not(windows))]
use std::os::unix::io::RawFd;

use crate::{
    capture::{Activated, Capture, PcapHandle},
    codec::PacketCodec,
    linktype::Linktype,
    packet::{Packet, PacketHeader},
    raw, Error,
};

use iterator::PacketIter;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Packet statistics for a capture
pub struct Stat {
    /// Number of packets received
    pub received: u32,
    /// Number of packets dropped because there was no room in the operating system's buffer when
    /// they arrived, because packets weren't being read fast enough
    pub dropped: u32,
    /// Number of packets dropped by the network interface or its driver
    pub if_dropped: u32,
}

impl Stat {
    fn new(received: u32, dropped: u32, if_dropped: u32) -> Stat {
        Stat {
            received,
            dropped,
            if_dropped,
        }
    }
}

#[repr(u32)]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
/// The direction of packets to be captured. Use with `Capture::direction`.
pub enum Direction {
    /// Capture packets received by or sent by the device. This is the default.
    InOut = raw::PCAP_D_INOUT,
    /// Only capture packets received by the device.
    In = raw::PCAP_D_IN,
    /// Only capture packets sent by the device.
    Out = raw::PCAP_D_OUT,
}

///# Activated captures include `Capture<Active>` and `Capture<Offline>`.
impl<T: Activated + ?Sized> Capture<T> {
    /// List the datalink types that this captured device supports.
    pub fn list_datalinks(&self) -> Result<Vec<Linktype>, Error> {
        unsafe {
            let mut links: *mut i32 = ptr::null_mut();
            let num = raw::pcap_list_datalinks(self.handle.as_ptr(), &mut links);
            let mut vec = vec![];
            if num > 0 {
                vec.extend(
                    slice::from_raw_parts(links, num as _)
                        .iter()
                        .cloned()
                        .map(Linktype),
                )
            }
            raw::pcap_free_datalinks(links);
            self.check_err(num > 0).and(Ok(vec))
        }
    }

    /// Set the datalink type for the current capture handle.
    pub fn set_datalink(&mut self, linktype: Linktype) -> Result<(), Error> {
        self.check_err(unsafe { raw::pcap_set_datalink(self.handle.as_ptr(), linktype.0) == 0 })
    }

    /// Get the current datalink type for this capture handle.
    pub fn get_datalink(&self) -> Linktype {
        unsafe { Linktype(raw::pcap_datalink(self.handle.as_ptr())) }
    }

    /// Create a `Savefile` context for recording captured packets using this `Capture`'s
    /// configurations.
    pub fn savefile<P: AsRef<Path>>(&self, path: P) -> Result<Savefile, Error> {
        let name = CString::new(path.as_ref().to_str().unwrap())?;
        let handle_opt = NonNull::<raw::pcap_dumper_t>::new(unsafe {
            raw::pcap_dump_open(self.handle.as_ptr(), name.as_ptr())
        });
        let handle = self
            .check_err(handle_opt.is_some())
            .map(|_| handle_opt.unwrap())?;
        Ok(Savefile::from(handle))
    }

    /// Create a `Savefile` context for recording captured packets using this `Capture`'s
    /// configurations. The output is written to a raw file descriptor which is opened in `"w"`
    /// mode.
    ///
    /// # Safety
    ///
    /// Unsafe, because the returned Savefile assumes it is the sole owner of the file descriptor.
    #[cfg(not(windows))]
    pub unsafe fn savefile_raw_fd(&self, fd: RawFd) -> Result<Savefile, Error> {
        open_raw_fd(fd, b'w').and_then(|file| {
            let handle_opt = NonNull::<raw::pcap_dumper_t>::new(raw::pcap_dump_fopen(
                self.handle.as_ptr(),
                file,
            ));
            let handle = self
                .check_err(handle_opt.is_some())
                .map(|_| handle_opt.unwrap())?;
            Ok(Savefile::from(handle))
        })
    }

    /// Reopen a `Savefile` context for recording captured packets using this `Capture`'s
    /// configurations. This is similar to `savefile()` but does not create the file if it
    /// does  not exist and, if it does already exist, and is a pcap file with the same
    /// byte order as the host opening the file, and has the same time stamp precision,
    /// link-layer header type,  and  snapshot length as p, it will write new packets
    /// at the end of the file.
    #[cfg(libpcap_1_7_2)]
    pub fn savefile_append<P: AsRef<Path>>(&self, path: P) -> Result<Savefile, Error> {
        let name = CString::new(path.as_ref().to_str().unwrap())?;
        let handle_opt = NonNull::<raw::pcap_dumper_t>::new(unsafe {
            raw::pcap_dump_open_append(self.handle.as_ptr(), name.as_ptr())
        });
        let handle = self
            .check_err(handle_opt.is_some())
            .map(|_| handle_opt.unwrap())?;
        Ok(Savefile::from(handle))
    }

    /// Set the direction of the capture
    pub fn direction(&self, direction: Direction) -> Result<(), Error> {
        self.check_err(unsafe {
            raw::pcap_setdirection(self.handle.as_ptr(), direction as u32 as _) == 0
        })
    }

    /// Blocks until a packet is returned from the capture handle or an error occurs.
    ///
    /// pcap captures packets and places them into a buffer which this function reads
    /// from.
    ///
    /// # Warning
    ///
    /// This buffer has a finite length, so if the buffer fills completely new
    /// packets will be discarded temporarily. This means that in realtime situations,
    /// you probably want to minimize the time between calls to next_packet() method.
    pub fn next_packet(&mut self) -> Result<Packet<'_>, Error> {
        unsafe {
            let mut header: *mut raw::pcap_pkthdr = ptr::null_mut();
            let mut packet: *const libc::c_uchar = ptr::null();
            let retcode = raw::pcap_next_ex(self.handle.as_ptr(), &mut header, &mut packet);
            match retcode {
                i if i >= 1 => {
                    // packet was read without issue
                    Ok(Packet::new(
                        &*(&*header as *const raw::pcap_pkthdr as *const PacketHeader),
                        slice::from_raw_parts(packet, (*header).caplen as _),
                    ))
                }
                0 => {
                    // packets are being read from a live capture and the
                    // timeout expired
                    Err(Error::TimeoutExpired)
                }
                -1 => {
                    // an error occured while reading the packet
                    Err(self.get_err())
                }
                -2 => {
                    // packets are being read from a "savefile" and there are no
                    // more packets to read
                    Err(Error::NoMorePackets)
                }
                // GRCOV_EXCL_START
                _ => {
                    // libpcap only defines codes >=1, 0, -1, and -2
                    unreachable!()
                } // GRCOV_EXCL_STOP
            }
        }
    }

    /// Return an iterator that call [`Self::next_packet()`] forever. Require a [`PacketCodec`]
    pub fn iter<C: PacketCodec>(self, codec: C) -> PacketIter<T, C> {
        PacketIter::new(self, codec)
    }

    pub fn for_each<F>(&mut self, count: Option<usize>, handler: F) -> Result<(), Error>
    where
        F: FnMut(Packet),
    {
        let cnt = match count {
            // Actually passing 0 down to pcap_loop would mean read forever.
            // We interpret it as "read nothing", so we just succeed immediately.
            Some(0) => return Ok(()),
            Some(cnt) => cnt
                .try_into()
                .expect("count of packets to read cannot exceed c_int::MAX"),
            None => -1,
        };

        let mut handler = HandlerFn {
            func: AssertUnwindSafe(handler),
            panic_payload: None,
            handle: self.handle.clone(),
        };
        let return_code = unsafe {
            raw::pcap_loop(
                self.handle.as_ptr(),
                cnt,
                HandlerFn::<F>::callback,
                &mut handler as *mut HandlerFn<AssertUnwindSafe<F>> as *mut u8,
            )
        };
        if let Some(e) = handler.panic_payload {
            resume_unwind(e);
        }
        self.check_err(return_code == 0)
    }

    /// Returns a thread-safe `BreakLoop` handle for calling pcap_breakloop() on an active capture.
    ///
    /// # Example
    ///
    /// ```no_run
    /// // Using an active capture
    /// use pcap::Device;
    ///
    /// let mut cap = Device::lookup().unwrap().unwrap().open().unwrap();
    ///
    /// let break_handle = cap.breakloop_handle();
    ///
    /// let capture_thread = std::thread::spawn(move || {
    ///     while let Ok(packet) = cap.next_packet() {
    ///         println!("received packet! {:?}", packet);
    ///     }
    /// });
    ///
    /// // Send break_handle to a separate thread (e.g. user input, signal handler, etc.)
    /// std::thread::spawn(move || {
    ///     std::thread::sleep(std::time::Duration::from_secs(1));
    ///     break_handle.breakloop();
    /// });
    ///
    /// capture_thread.join().unwrap();
    /// ```
    pub fn breakloop_handle(&mut self) -> BreakLoop {
        BreakLoop {
            handle: Arc::<PcapHandle>::downgrade(&self.handle),
        }
    }

    /// Compiles the string into a filter program using `pcap_compile`.
    pub fn compile(&self, program: &str, optimize: bool) -> Result<BpfProgram, Error> {
        let program = CString::new(program)?;

        unsafe {
            let mut bpf_program: raw::bpf_program = mem::zeroed();
            let ret = raw::pcap_compile(
                self.handle.as_ptr(),
                &mut bpf_program,
                program.as_ptr(),
                optimize as libc::c_int,
                0,
            );
            self.check_err(ret != -1).and(Ok(BpfProgram(bpf_program)))
        }
    }

    /// Sets the filter on the capture using the given BPF program string. Internally this is
    /// compiled using `pcap_compile()`. `optimize` controls whether optimization on the resulting
    /// code is performed
    ///
    /// See <http://biot.com/capstats/bpf.html> for more information about this syntax.
    pub fn filter(&mut self, program: &str, optimize: bool) -> Result<(), Error> {
        let mut bpf_program = self.compile(program, optimize)?;
        let ret = unsafe { raw::pcap_setfilter(self.handle.as_ptr(), &mut bpf_program.0) };
        self.check_err(ret != -1)
    }

    /// Get capture statistics about this capture. The values represent packet statistics from the
    /// start of the run to the time of the call.
    ///
    /// See <https://www.tcpdump.org/manpages/pcap_stats.3pcap.html> for per-platform caveats about
    /// how packet statistics are calculated.
    pub fn stats(&mut self) -> Result<Stat, Error> {
        unsafe {
            let mut stats: raw::pcap_stat = mem::zeroed();
            self.check_err(raw::pcap_stats(self.handle.as_ptr(), &mut stats) != -1)
                .map(|_| Stat::new(stats.ps_recv, stats.ps_drop, stats.ps_ifdrop))
        }
    }
}

// Handler and its associated function let us create an extern "C" fn which dispatches to a normal
// Rust FnMut, which may be a closure with a captured environment. The *only* purpose of this
// generic parameter is to ensure that in Capture::pcap_loop that we pass the right function
// pointer and the right data pointer to pcap_loop.
struct HandlerFn<F> {
    func: F,
    panic_payload: Option<Box<dyn Any + Send>>,
    handle: Arc<PcapHandle>,
}

impl<F> HandlerFn<F>
where
    F: FnMut(Packet),
{
    extern "C" fn callback(
        slf: *mut libc::c_uchar,
        header: *const raw::pcap_pkthdr,
        packet: *const libc::c_uchar,
    ) {
        unsafe {
            let packet = Packet::new(
                &*(header as *const PacketHeader),
                slice::from_raw_parts(packet, (*header).caplen as _),
            );

            let slf = slf as *mut Self;
            let func = &mut (*slf).func;
            let mut func = AssertUnwindSafe(func);
            // If our handler function panics, we need to prevent it from unwinding across the
            // FFI boundary. If the handler panics we catch the unwind here, break out of
            // pcap_loop, and resume the unwind outside.
            if let Err(e) = catch_unwind(move || func(packet)) {
                (*slf).panic_payload = Some(e);
                raw::pcap_breakloop((*slf).handle.as_ptr());
            }
        }
    }
}

impl<T: Activated> From<Capture<T>> for Capture<dyn Activated> {
    fn from(cap: Capture<T>) -> Capture<dyn Activated> {
        unsafe { mem::transmute(cap) }
    }
}

/// BreakLoop can safely be sent to other threads such as signal handlers to abort
/// blocking capture loops such as `Capture::next_packet` and `Capture::for_each`.
///
/// See <https://www.tcpdump.org/manpages/pcap_breakloop.3pcap.html> for per-platform caveats about
/// how breakloop can wake up blocked threads.
pub struct BreakLoop {
    handle: Weak<PcapHandle>,
}

unsafe impl Send for BreakLoop {}
unsafe impl Sync for BreakLoop {}

impl BreakLoop {
    /// Calls `pcap_breakloop` to make the blocking loop of a pcap capture return.
    /// The call is a no-op if the handle is invalid.
    ///
    /// # Safety
    ///
    /// Can be called from any thread, but **must not** be used inside a
    /// signal handler unless the owning `Capture` is guaranteed to still
    /// be alive.
    ///
    /// The signal handler should defer the execution of `BreakLoop::breakloop()`
    /// to a thread instead for safety.
    pub fn breakloop(&self) {
        if let Some(handle) = self.handle.upgrade() {
            unsafe { raw::pcap_breakloop(handle.as_ptr()) };
        }
    }
}

/// Abstraction for writing pcap savefiles, which can be read afterwards via `Capture::from_file()`.
pub struct Savefile {
    handle: NonNull<raw::pcap_dumper_t>,
}

// Just like a Capture, a Savefile is safe to Send as it encapsulates the entire lifetime of
// `raw::pcap_dumper_t *`, but it is not safe to Sync as libpcap does not promise thread-safe access
// to the same `raw::pcap_dumper_t *` from multiple threads.
unsafe impl Send for Savefile {}

impl Savefile {
    /// Write a packet to a capture file
    pub fn write(&mut self, packet: &Packet<'_>) {
        unsafe {
            raw::pcap_dump(
                self.handle.as_ptr() as _,
                &*(packet.header as *const PacketHeader as *const raw::pcap_pkthdr),
                packet.data.as_ptr(),
            );
        }
    }

    /// Flushes all the packets that haven't been written to the savefile
    pub fn flush(&mut self) -> Result<(), Error> {
        if unsafe { raw::pcap_dump_flush(self.handle.as_ptr() as _) } != 0 {
            return Err(Error::ErrnoError(errno::errno()));
        }

        Ok(())
    }
}

impl From<NonNull<raw::pcap_dumper_t>> for Savefile {
    fn from(handle: NonNull<raw::pcap_dumper_t>) -> Self {
        Savefile { handle }
    }
}

impl Drop for Savefile {
    fn drop(&mut self) {
        unsafe { raw::pcap_dump_close(self.handle.as_ptr()) }
    }
}

#[repr(transparent)]
pub struct BpfInstruction(raw::bpf_insn);
#[repr(transparent)]
pub struct BpfProgram(raw::bpf_program);

impl BpfProgram {
    /// checks whether a filter matches a packet
    pub fn filter(&self, buf: &[u8]) -> bool {
        let header: raw::pcap_pkthdr = raw::pcap_pkthdr {
            ts: libc::timeval {
                tv_sec: 0,
                tv_usec: 0,
            },
            caplen: buf.len() as u32,
            len: buf.len() as u32,
        };
        unsafe { raw::pcap_offline_filter(&self.0, &header, buf.as_ptr()) > 0 }
    }

    pub fn get_instructions(&self) -> &[BpfInstruction] {
        unsafe {
            slice::from_raw_parts(
                self.0.bf_insns as *const BpfInstruction,
                self.0.bf_len as usize,
            )
        }
    }
}

impl Drop for BpfProgram {
    fn drop(&mut self) {
        unsafe { raw::pcap_freecode(&mut self.0) }
    }
}

impl fmt::Display for BpfInstruction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} {} {} {}",
            self.0.code, self.0.jt, self.0.jf, self.0.k
        )
    }
}

unsafe impl Send for BpfProgram {}

#[cfg(not(windows))]
/// Open a raw file descriptor.
///
/// # Safety
///
/// Unsafe, because the returned FILE assumes it is the sole owner of the file descriptor.
pub unsafe fn open_raw_fd(fd: RawFd, mode: u8) -> Result<*mut libc::FILE, Error> {
    let mode = [mode, 0];
    libc::fdopen(fd, mode.as_ptr() as _)
        .as_mut()
        .map(|f| f as _)
        .ok_or(Error::InvalidRawFd)
}

// GRCOV_EXCL_START
#[cfg(test)]
mod testmod {
    use super::*;

    pub static TS: libc::timeval = libc::timeval {
        tv_sec: 5,
        tv_usec: 50,
    };
    pub static LEN: u32 = DATA.len() as u32;
    pub static CAPLEN: u32 = LEN;

    pub static mut PKTHDR: raw::pcap_pkthdr = raw::pcap_pkthdr {
        ts: TS,
        caplen: CAPLEN,
        len: LEN,
    };
    pub static PACKET_HEADER: PacketHeader = PacketHeader {
        ts: TS,
        caplen: CAPLEN,
        len: LEN,
    };

    pub static DATA: [u8; 4] = [4, 5, 6, 7];
    pub static PACKET: Packet = Packet {
        header: &PACKET_HEADER,
        data: &DATA,
    };

    pub struct NextExContext(raw::__pcap_next_ex::Context);
    pub fn next_ex_expect(pcap: *mut raw::pcap_t) -> NextExContext {
        let data_ptr: *const libc::c_uchar = DATA.as_ptr();
        #[allow(unused_unsafe)] // unsafe still needed to compile on MSRV
        let pkthdr_ptr: *mut raw::pcap_pkthdr = unsafe { std::ptr::addr_of_mut!(PKTHDR) };

        let ctx = raw::pcap_next_ex_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap)
            .return_once_st(move |_, arg2, arg3| {
                unsafe {
                    *arg2 = pkthdr_ptr;
                    *arg3 = data_ptr;
                }
                CAPLEN as i32
            });

        NextExContext(ctx)
    }
}
// GRCOV_EXCL_STOP

#[cfg(test)]
mod tests {
    use crate::{
        capture::{
            activated::testmod::{next_ex_expect, PACKET},
            testmod::test_capture,
            Active, Capture, Offline,
        },
        raw::testmod::{as_pcap_dumper_t, as_pcap_t, geterr_expect, RAWMTX},
    };

    use super::*;

    #[test]
    fn test_list_datalinks() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let capture: Capture<dyn Activated> = test_capture.capture.into();

        let ctx = raw::pcap_list_datalinks_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once_st(|_, _| 0);

        let ctx = raw::pcap_free_datalinks_context();
        ctx.expect().return_once(|_| {});

        let _err = geterr_expect(pcap);

        let result = capture.list_datalinks();
        assert!(result.is_err());

        let mut datalinks: [i32; 4] = [0, 1, 2, 3];
        let links: *mut i32 = datalinks.as_mut_ptr();
        let len = datalinks.len();

        let ctx = raw::pcap_list_datalinks_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once_st(move |_, arg2| {
                unsafe { *arg2 = links };
                len as i32
            });

        let ctx = raw::pcap_free_datalinks_context();
        ctx.checkpoint();
        ctx.expect().return_once(|_| {});

        let pcap_datalinks = capture.list_datalinks().unwrap();
        assert_eq!(
            pcap_datalinks,
            datalinks.iter().cloned().map(Linktype).collect::<Vec<_>>()
        );
    }

    #[test]
    fn test_set_datalink() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture: Capture<dyn Activated> = test_capture.capture.into();

        let ctx = raw::pcap_set_datalink_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);

        let result = capture.set_datalink(Linktype::ETHERNET);
        assert!(result.is_ok());

        let ctx = raw::pcap_set_datalink_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| -1);

        let _err = geterr_expect(pcap);

        let result = capture.set_datalink(Linktype::ETHERNET);
        assert!(result.is_err());
    }

    #[test]
    fn test_get_datalink() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let capture: Capture<dyn Activated> = test_capture.capture.into();

        let ctx = raw::pcap_datalink_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap)
            .return_once(|_| 1);

        let linktype = capture.get_datalink();
        assert_eq!(linktype, Linktype::ETHERNET);
    }

    #[test]
    fn unify_activated() {
        #![allow(dead_code)]
        fn test1() -> Capture<Active> {
            panic!();
        }

        fn test2() -> Capture<Offline> {
            panic!();
        }

        fn maybe(a: bool) -> Capture<dyn Activated> {
            if a {
                test1().into()
            } else {
                test2().into()
            }
        }

        fn also_maybe(a: &mut Capture<dyn Activated>) {
            a.filter("whatever filter string, this won't be run anyway", false)
                .unwrap();
        }
    }

    #[test]
    fn test_breakloop_capture_dropped() {
        let _m = RAWMTX.lock();

        let mut value: isize = 1234;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture: Capture<dyn Activated> = test_capture.capture.into();

        let ctx = raw::pcap_breakloop_context();
        ctx.expect()
            .withf_st(move |h| *h == pcap)
            .return_const(())
            .times(1);

        let break_handle = capture.breakloop_handle();

        break_handle.breakloop();

        drop(capture);

        break_handle.breakloop(); // this call does not trigger mock after drop
    }

    #[test]
    fn test_savefile() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let mut value: isize = 888;
        let pcap_dumper = as_pcap_dumper_t(&mut value);

        let test_capture = test_capture::<Offline>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_dump_open_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once_st(move |_, _| pcap_dumper);

        let ctx = raw::pcap_dump_close_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap_dumper)
            .return_once(|_| {});

        let result = capture.savefile("path/to/nowhere");
        assert!(result.is_ok());
    }

    #[test]
    #[cfg(libpcap_1_7_2)]
    fn test_savefile_append() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let mut value: isize = 888;
        let pcap_dumper = as_pcap_dumper_t(&mut value);

        let test_capture = test_capture::<Offline>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_dump_open_append_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once_st(move |_, _| pcap_dumper);

        let ctx = raw::pcap_dump_close_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap_dumper)
            .return_once(|_| {});

        let result = capture.savefile_append("path/to/nowhere");
        assert!(result.is_ok());
    }

    #[test]
    fn test_savefile_error() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Offline>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_dump_open_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| std::ptr::null_mut());

        let _err = geterr_expect(pcap);

        let result = capture.savefile("path/to/nowhere");
        assert!(result.is_err());
    }

    #[test]
    #[cfg(libpcap_1_7_2)]
    fn test_savefile_append_error() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Offline>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_dump_open_append_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| std::ptr::null_mut());

        let _err = geterr_expect(pcap);

        let result = capture.savefile_append("path/to/nowhere");
        assert!(result.is_err());
    }

    #[test]
    fn test_savefile_ops() {
        let _m = RAWMTX.lock();

        let mut value: isize = 888;
        let pcap_dumper = as_pcap_dumper_t(&mut value);

        let ctx = raw::pcap_dump_close_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap_dumper)
            .return_once(|_| {});

        let mut savefile = Savefile {
            handle: NonNull::new(pcap_dumper).unwrap(),
        };

        let ctx = raw::pcap_dump_context();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap_dumper as _)
            .return_once(|_, _, _| {});

        savefile.write(&PACKET);

        let ctx = raw::pcap_dump_flush_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap_dumper)
            .return_once(|_| 0);

        let result = savefile.flush();
        assert!(result.is_ok());

        let ctx = raw::pcap_dump_flush_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap_dumper)
            .return_once(|_| -1);

        let result = savefile.flush();
        assert!(result.is_err());
    }

    #[test]
    fn test_direction() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_setdirection_context();
        ctx.expect()
            .withf_st(move |arg1, arg2| (*arg1 == pcap) && (*arg2 == raw::PCAP_D_OUT))
            .return_once(|_, _| 0);

        let result = capture.direction(Direction::Out);
        assert!(result.is_ok());

        let ctx = raw::pcap_setdirection_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |arg1, arg2| (*arg1 == pcap) && (*arg2 == raw::PCAP_D_OUT))
            .return_once(|_, _| -1);

        let _err = geterr_expect(pcap);

        let result = capture.direction(Direction::Out);
        assert!(result.is_err());

        // For code coverage of the derive line.
        assert_ne!(Direction::In, Direction::InOut);
        assert_ne!(Direction::In, Direction::Out);
        assert_ne!(Direction::InOut, Direction::Out);
    }

    #[test]
    fn test_next_packet() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture = test_capture.capture;

        let _nxt = next_ex_expect(pcap);

        let next_packet = capture.next_packet().unwrap();
        assert_eq!(next_packet, PACKET);
    }

    #[test]
    fn test_next_packet_timeout() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture = test_capture.capture;

        let ctx = raw::pcap_next_ex_context();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap)
            .return_once_st(move |_, _, _| 0);

        let err = capture.next_packet().unwrap_err();
        assert_eq!(err, Error::TimeoutExpired);
    }

    #[test]
    fn test_next_packet_read_error() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture = test_capture.capture;

        let ctx = raw::pcap_next_ex_context();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap)
            .return_once_st(move |_, _, _| -1);

        let _err = geterr_expect(pcap);

        let result = capture.next_packet();
        assert!(result.is_err());
    }

    #[test]
    fn test_next_packet_no_more_packets() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Offline>(pcap);
        let mut capture = test_capture.capture;

        let ctx = raw::pcap_next_ex_context();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap)
            .return_once_st(move |_, _, _| -2);

        let err = capture.next_packet().unwrap_err();
        assert_eq!(err, Error::NoMorePackets);
    }

    #[test]
    fn test_compile() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_compile_context();
        ctx.expect()
            .withf_st(move |arg1, _, _, _, _| *arg1 == pcap)
            .return_once(|_, _, _, _, _| -1);

        let _err = geterr_expect(pcap);

        let ctx = raw::pcap_freecode_context();
        ctx.expect().return_once(|_| {});

        let result = capture.compile("some bpf program", false);
        assert!(result.is_err());

        let ctx = raw::pcap_compile_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |arg1, _, _, _, _| *arg1 == pcap)
            .return_once(|_, _, _, _, _| 0);

        let ctx = raw::pcap_freecode_context();
        ctx.checkpoint();
        ctx.expect().return_once(|_| {});

        let result = capture.compile("some bpf program", false);
        assert!(result.is_ok());
    }

    #[test]
    fn test_filter() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture = test_capture.capture;

        let ctx = raw::pcap_compile_context();
        ctx.expect()
            .withf_st(move |arg1, _, _, _, _| *arg1 == pcap)
            .return_once(|_, _, _, _, _| 0);

        let ctx = raw::pcap_setfilter_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| -1);

        let _err = geterr_expect(pcap);

        let ctx = raw::pcap_freecode_context();
        ctx.expect().return_once(|_| {});

        let result = capture.filter("some bpf program", false);
        assert!(result.is_err());

        let ctx = raw::pcap_compile_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |arg1, _, _, _, _| *arg1 == pcap)
            .return_once(|_, _, _, _, _| 0);

        let ctx = raw::pcap_setfilter_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);

        let ctx = raw::pcap_freecode_context();
        ctx.checkpoint();
        ctx.expect().return_once(|_| {});

        let result = capture.compile("some bpf program", false);
        assert!(result.is_ok());
    }

    #[test]
    fn test_stats() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture = test_capture.capture;

        let stat = raw::pcap_stat {
            ps_recv: 1,
            ps_drop: 2,
            ps_ifdrop: 3,
        };

        let ctx = raw::pcap_stats_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once_st(move |_, arg2| {
                unsafe { *arg2 = stat };
                0
            });

        let stats = capture.stats().unwrap();
        assert_eq!(stats, Stat::new(stat.ps_recv, stat.ps_drop, stat.ps_ifdrop));

        let ctx = raw::pcap_stats_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once_st(move |_, _| -1);

        let _err = geterr_expect(pcap);

        let result = capture.stats();
        assert!(result.is_err());
    }

    #[test]
    fn test_bpf_instruction_display() {
        let instr = BpfInstruction(raw::bpf_insn {
            code: 1,
            jt: 2,
            jf: 3,
            k: 4,
        });
        assert_eq!(format!("{instr}"), "1 2 3 4");
    }

    #[test]
    fn read_packet_via_pcap_loop() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture: Capture<dyn Activated> = test_capture.capture.into();

        let ctx = raw::pcap_loop_context();
        ctx.expect()
            .withf_st(move |arg1, cnt, _, _| *arg1 == pcap && *cnt == -1)
            .return_once_st(move |_, _, func, data| {
                let header = raw::pcap_pkthdr {
                    ts: libc::timeval {
                        tv_sec: 0,
                        tv_usec: 0,
                    },
                    caplen: 0,
                    len: 0,
                };
                let packet_data = &[];
                func(data, &header, packet_data.as_ptr());
                0
            });

        let mut packets = 0;
        capture
            .for_each(None, |_| {
                packets += 1;
            })
            .unwrap();
        assert_eq!(packets, 1);
    }

    #[test]
    #[should_panic = "panic in callback"]
    fn panic_in_pcap_loop() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture: Capture<dyn Activated> = test_capture.capture.into();

        let ctx = raw::pcap_loop_context();
        ctx.expect()
            .withf_st(move |arg1, cnt, _, _| *arg1 == pcap && *cnt == -1)
            .return_once_st(move |_, _, func, data| {
                let header = raw::pcap_pkthdr {
                    ts: libc::timeval {
                        tv_sec: 0,
                        tv_usec: 0,
                    },
                    caplen: 0,
                    len: 0,
                };
                let packet_data = &[];
                func(data, &header, packet_data.as_ptr());
                0
            });

        let ctx = raw::pcap_breakloop_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap)
            .return_once_st(move |_| {});

        capture
            .for_each(None, |_| panic!("panic in callback"))
            .unwrap();
    }

    #[test]
    fn for_each_with_count() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture: Capture<dyn Activated> = test_capture.capture.into();

        let ctx = raw::pcap_loop_context();
        ctx.expect()
            .withf_st(move |arg1, cnt, _, _| *arg1 == pcap && *cnt == 2)
            .return_once_st(move |_, _, func, data| {
                let header = raw::pcap_pkthdr {
                    ts: libc::timeval {
                        tv_sec: 0,
                        tv_usec: 0,
                    },
                    caplen: 0,
                    len: 0,
                };
                let packet_data = &[];
                func(data, &header, packet_data.as_ptr());
                func(data, &header, packet_data.as_ptr());
                0
            });

        let mut packets = 0;
        capture
            .for_each(Some(2), |_| {
                packets += 1;
            })
            .unwrap();
        assert_eq!(packets, 2);
    }

    #[test]
    fn for_each_with_count_0() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let mut capture: Capture<dyn Activated> = test_capture.capture.into();

        let mut packets = 0;
        capture
            .for_each(Some(0), |_| {
                packets += 1;
            })
            .unwrap();
        assert_eq!(packets, 0);
    }
}
