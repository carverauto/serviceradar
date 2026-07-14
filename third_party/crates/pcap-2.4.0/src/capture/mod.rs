pub mod activated;
pub mod inactive;
#[cfg(all(not(windows), feature = "capture-stream"))]
#[cfg_attr(docsrs, doc(cfg(all(not(windows), feature = "capture-stream"))))]
pub mod selectable;

use std::{
    ffi::CString,
    marker::PhantomData,
    ptr::{self, NonNull},
    sync::Arc,
};

#[cfg(windows)]
use windows_sys::Win32::Foundation::HANDLE;

use crate::{raw, Error};

/// Phantom type representing an inactive capture handle.
pub enum Inactive {}

/// Phantom type representing an active capture handle.
pub enum Active {}

/// Phantom type representing an offline capture handle, from a pcap dump file.
/// Implements `Activated` because it behaves nearly the same as a live handle.
pub enum Offline {}

/// Phantom type representing a dead capture handle.  This can be use to create
/// new save files that are not generated from an active capture.
/// Implements `Activated` because it behaves nearly the same as a live handle.
pub enum Dead {}

/// `Capture`s can be in different states at different times, and in these states they
/// may or may not have particular capabilities. This trait is implemented by phantom
/// types which allows us to punt these invariants to the type system to avoid runtime
/// errors.
pub trait Activated: State {}

impl Activated for Active {}

impl Activated for Offline {}

impl Activated for Dead {}

/// `Capture`s can be in different states at different times, and in these states they
/// may or may not have particular capabilities. This trait is implemented by phantom
/// types which allows us to punt these invariants to the type system to avoid runtime
/// errors.
pub trait State {}

impl State for Inactive {}

impl State for Active {}

impl State for Offline {}

impl State for Dead {}

/// This is a pcap capture handle which is an abstraction over the `pcap_t` provided by pcap.
/// There are many ways to instantiate and interact with a pcap handle, so phantom types are
/// used to express these behaviors.
///
/// **`Capture<Inactive>`** is created via `Capture::from_device()`. This handle is inactive,
/// so you cannot (yet) obtain packets from it. However, you can configure things like the
/// buffer size, snaplen, timeout, and promiscuity before you activate it.
///
/// **`Capture<Active>`** is created by calling `.open()` on a `Capture<Inactive>`. This
/// activates the capture handle, allowing you to get packets with `.next_packet()` or apply filters
/// with `.filter()`.
///
/// **`Capture<Offline>`** is created via `Capture::from_file()`. This allows you to read a
/// pcap format dump file as if you were opening an interface -- very useful for testing or
/// analysis.
///
/// **`Capture<Dead>`** is created via `Capture::dead()`. This allows you to create a pcap
/// format dump file without needing an active capture.
///
/// # Example:
///
/// ```no_run
/// # use pcap::{Capture, Device};
/// let mut cap = Capture::from_device(Device::lookup().unwrap().unwrap()) // open the "default" interface
///               .unwrap() // assume the device exists and we are authorized to open it
///               .open() // activate the handle
///               .unwrap(); // assume activation worked
///
/// while let Ok(packet) = cap.next_packet() {
///     println!("received packet! {:?}", packet);
/// }
/// ```
pub struct Capture<T: State + ?Sized> {
    nonblock: bool,
    handle: Arc<PcapHandle>,
    _marker: PhantomData<T>,
}

struct PcapHandle {
    handle: NonNull<raw::pcap_t>,
}

impl PcapHandle {
    fn as_ptr(&self) -> *mut raw::pcap_t {
        self.handle.as_ptr()
    }
}

// `PcapHandle` is safe to Send as it encapsulates the entire lifetime of `raw::pcap_t *`
// `PcapHandle` is only Sync under special circumstances when used in thread-safe functions such as
// the `pcap_breakloop` function. The Sync correctness is left to the wrapping structure to provide.
unsafe impl Send for PcapHandle {}

impl Drop for PcapHandle {
    fn drop(&mut self) {
        unsafe { raw::pcap_close(self.handle.as_ptr()) }
    }
}

unsafe impl<T: State + ?Sized> Send for Capture<T> {}

// `Capture` is not safe to implement Sync as the libpcap functions it uses are not promised to have
// thread-safe access to the same `raw::pcap_t *` from multiple threads.
#[allow(clippy::arc_with_non_send_sync)]
impl<T: State + ?Sized> From<NonNull<raw::pcap_t>> for Capture<T> {
    fn from(handle: NonNull<raw::pcap_t>) -> Self {
        Capture {
            nonblock: false,
            handle: Arc::new(PcapHandle { handle }),
            _marker: PhantomData,
        }
    }
}

impl<T: State + ?Sized> Capture<T> {
    fn new_raw<F>(path: Option<&str>, func: F) -> Result<Capture<T>, Error>
    where
        F: FnOnce(*const libc::c_char, *mut libc::c_char) -> *mut raw::pcap_t,
    {
        Error::with_errbuf(|err| {
            let handle = match path {
                None => func(ptr::null(), err),
                Some(path) => {
                    let path = CString::new(path)?;
                    func(path.as_ptr(), err)
                }
            };
            Ok(Capture::from(
                NonNull::<raw::pcap_t>::new(handle).ok_or_else(|| unsafe { Error::new(err) })?,
            ))
        })
    }

    pub fn is_nonblock(&self) -> bool {
        self.nonblock
    }

    pub fn as_ptr(&self) -> *mut raw::pcap_t {
        self.handle.as_ptr()
    }

    /// Set the minumum amount of data received by the kernel in a single call.
    ///
    /// Note that this value is set to 0 when the capture is set to immediate mode. You should not
    /// call `min_to_copy` on captures in immediate mode if you want them to stay in immediate mode.
    #[cfg(windows)]
    pub fn min_to_copy(self, to: i32) -> Capture<T> {
        unsafe {
            raw::pcap_setmintocopy(self.handle.as_ptr(), to as _);
        }
        self
    }

    /// Get handle to the Capture context's internal Win32 event semaphore.
    ///
    /// Setting this event will cause a blocking capture call to unblock and return.
    ///
    /// # Example
    /// The _winevt_ example demonstrates how to use the event semaphore to send command requests
    /// to a capture loop running in a separate thread.
    ///
    /// # Safety
    ///
    /// The caller must ensure that the `Capture` context outlives the returned `HANDLE` since it is
    /// a kernel object owned by the `Capture`'s pcap context.
    #[cfg(windows)]
    pub unsafe fn get_event(&self) -> HANDLE {
        raw::pcap_getevent(self.handle.as_ptr())
    }

    fn check_err(&self, success: bool) -> Result<(), Error> {
        if success {
            Ok(())
        } else {
            Err(self.get_err())
        }
    }

    fn get_err(&self) -> Error {
        unsafe { Error::new(raw::pcap_geterr(self.handle.as_ptr())) }
    }
}

#[repr(u32)]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
/// Timestamp resolution types
///
/// Not all systems and interfaces will necessarily support all of these resolutions when doing
/// live captures; all of them can be requested when reading a safefile.
pub enum Precision {
    /// Use timestamps with microsecond precision. This is the default.
    Micro = 0,
    /// Use timestamps with nanosecond precision.
    Nano = 1,
}

// GRCOV_EXCL_START
#[cfg(test)]
pub mod testmod {
    use raw::testmod::RAWMTX;

    use super::*;

    pub struct TestCapture<T: State + ?Sized> {
        pub capture: Capture<T>,
        _close_ctx: raw::__pcap_close::Context,
    }

    pub fn test_capture<T: State + ?Sized>(pcap: *mut raw::pcap_t) -> TestCapture<T> {
        // Lock must be acquired by caller.
        assert!(RAWMTX.try_lock().is_err());

        let ctx = raw::pcap_close_context();
        ctx.checkpoint();
        ctx.expect()
            .withf_st(move |ptr| *ptr == pcap)
            .return_once(|_| {});

        TestCapture {
            capture: Capture::<T>::from(NonNull::new(pcap).unwrap()),
            _close_ctx: ctx,
        }
    }
}
// GRCOV_EXCL_STOP

#[cfg(test)]
mod tests {
    use crate::{
        capture::testmod::test_capture,
        raw::testmod::{as_pcap_t, RAWMTX},
    };

    use super::*;

    #[test]
    fn test_capture_getters() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;

        assert!(!capture.is_nonblock());
        assert_eq!(capture.as_ptr(), capture.handle.as_ptr());
    }

    #[test]
    #[cfg(windows)]
    fn test_min_to_copy() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_setmintocopy_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);

        let _capture = capture.min_to_copy(5);
    }

    #[test]
    #[cfg(windows)]
    fn test_get_event() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_getevent_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap)
            .return_once(|_| 5);

        let handle = unsafe { capture.get_event() };
        assert_eq!(handle, 5);
    }

    #[test]
    fn test_precision() {
        assert_ne!(Precision::Micro, Precision::Nano);
    }
}
