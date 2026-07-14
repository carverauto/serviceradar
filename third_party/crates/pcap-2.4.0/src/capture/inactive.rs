use std::mem;

use crate::{
    capture::{Active, Capture, Inactive},
    device::Device,
    raw, Error,
};

#[cfg(libpcap_1_5_0)]
use crate::capture::Precision;

impl Capture<Inactive> {
    /// Opens a capture handle for a device. You can pass a `Device` or an `&str` device
    /// name here. The handle is inactive, but can be activated via `.open()`.
    ///
    /// # Example
    /// ```
    /// use pcap::*;
    ///
    /// // Usage 1: Capture from a single owned device
    /// let dev: Device = pcap::Device::lookup()
    ///     .expect("device lookup failed")
    ///     .expect("no device available");
    /// let cap1 = Capture::from_device(dev);
    ///
    /// // Usage 2: Capture from an element of device list.
    /// let list: Vec<Device> = pcap::Device::list().unwrap();
    /// let cap2 = Capture::from_device(list[0].clone());
    ///
    /// // Usage 3: Capture from `&str` device name
    /// let cap3 = Capture::from_device("eth0");
    /// ```
    pub fn from_device<D: Into<Device>>(device: D) -> Result<Capture<Inactive>, Error> {
        let device: Device = device.into();
        Capture::new_raw(Some(&device.name), |name, err| unsafe {
            raw::pcap_create(name, err)
        })
    }

    /// Activates an inactive capture created from `Capture::from_device()` or returns an error.
    pub fn open(self) -> Result<Capture<Active>, Error> {
        unsafe {
            self.check_err(raw::pcap_activate(self.handle.as_ptr()) == 0)?;
            Ok(mem::transmute::<Capture<Inactive>, Capture<Active>>(self))
        }
    }

    /// Set the read timeout for the Capture. By default, this is 0, so it will block indefinitely.
    pub fn timeout(self, ms: i32) -> Capture<Inactive> {
        unsafe { raw::pcap_set_timeout(self.handle.as_ptr(), ms) };
        self
    }

    /// Set the time stamp type to be used by a capture device.
    #[cfg(libpcap_1_2_1)]
    pub fn tstamp_type(self, tstamp_type: TimestampType) -> Capture<Inactive> {
        unsafe { raw::pcap_set_tstamp_type(self.handle.as_ptr(), tstamp_type as _) };
        self
    }

    /// Set promiscuous mode on or off. By default, this is off.
    pub fn promisc(self, to: bool) -> Capture<Inactive> {
        unsafe { raw::pcap_set_promisc(self.handle.as_ptr(), to as _) };
        self
    }

    /// Set immediate mode on or off. By default, this is off.
    ///
    /// Note that in WinPcap immediate mode is set by passing a 0 argument to `min_to_copy`.
    /// Immediate mode will be unset if `min_to_copy` is later called with a non-zero argument.
    /// Immediate mode is unset by resetting `min_to_copy` to the WinPcap default possibly changing
    /// a previously set value. When using `min_to_copy`, it is best to avoid `immediate_mode`.
    #[cfg(any(libpcap_1_5_0, windows))]
    pub fn immediate_mode(self, to: bool) -> Capture<Inactive> {
        // Prior to 1.5.0 when `pcap_set_immediate_mode` was introduced, the necessary steps to set
        // immediate mode were more complicated, depended on the OS, and in some configurations had
        // to be set on an active capture. See
        // https://www.tcpdump.org/manpages/pcap_set_immediate_mode.3pcap.html. Since we do not
        // expect pre-1.5.0 version on unix systems in the wild, we simply ignore those cases.
        #[cfg(libpcap_1_5_0)]
        unsafe {
            raw::pcap_set_immediate_mode(self.handle.as_ptr(), to as _)
        };

        // In WinPcap we use `pcap_setmintocopy` as it does not have `pcap_set_immediate_mode`.
        #[cfg(all(windows, not(libpcap_1_5_0)))]
        unsafe {
            raw::pcap_setmintocopy(
                self.handle.as_ptr(),
                if to {
                    0
                } else {
                    raw::WINPCAP_MINTOCOPY_DEFAULT
                },
            )
        };

        self
    }

    /// Set want_pktap to true or false. The default is maintained by libpcap.
    #[cfg(all(libpcap_1_5_3, target_os = "macos"))]
    pub fn want_pktap(self, to: bool) -> Capture<Inactive> {
        unsafe { raw::pcap_set_want_pktap(self.handle.as_ptr(), to as _) };

        self
    }

    /// Set rfmon mode on or off. The default is maintained by pcap.
    #[cfg(not(windows))]
    pub fn rfmon(self, to: bool) -> Capture<Inactive> {
        unsafe { raw::pcap_set_rfmon(self.handle.as_ptr(), to as _) };
        self
    }

    /// Set the buffer size for incoming packet data.
    ///
    /// The default is 1000000. This should always be larger than the snaplen.
    pub fn buffer_size(self, to: i32) -> Capture<Inactive> {
        unsafe { raw::pcap_set_buffer_size(self.handle.as_ptr(), to) };
        self
    }

    /// Set the time stamp precision returned in captures.
    #[cfg(libpcap_1_5_0)]
    pub fn precision(self, precision: Precision) -> Capture<Inactive> {
        unsafe { raw::pcap_set_tstamp_precision(self.handle.as_ptr(), precision as _) };
        self
    }

    /// Set the snaplen size (the maximum length of a packet captured into the buffer).
    /// Useful if you only want certain headers, but not the entire packet.
    ///
    /// The default is 65535.
    pub fn snaplen(self, to: i32) -> Capture<Inactive> {
        unsafe { raw::pcap_set_snaplen(self.handle.as_ptr(), to) };
        self
    }
}

#[repr(i32)]
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
/// Timestamp types
///
/// Not all systems and interfaces will necessarily support all of these.
///
/// Note that time stamps synchronized with the system clock can go backwards, as the system clock
/// can go backwards.  If a clock is not in sync with the system clock, that could be because the
/// system clock isn't keeping accurate time, because the other clock isn't keeping accurate time,
/// or both.
///
/// Note that host-provided time stamps generally correspond to the time when the time-stamping
/// code sees the packet; this could be some unknown amount of time after the first or last bit of
/// the packet is received by the network adapter, due to batching of interrupts for packet
/// arrival, queueing delays, etc..
pub enum TimestampType {
    /// Timestamps are provided by the host machine, rather than by the capture device.
    ///
    /// The characteristics of the timestamp are unknown.
    Host = 0,
    /// A timestamp provided by the host machine that is low precision but relatively cheap to
    /// fetch.
    ///
    /// This is normally done using the system clock, so it's normally synchronized with times
    /// you'd fetch from system calls.
    HostLowPrec = 1,
    /// A timestamp provided by the host machine that is high precision. It might be more expensive
    /// to fetch.
    ///
    /// The timestamp might or might not be synchronized with the system clock, and might have
    /// problems with time stamps for packets received on different CPUs, depending on the
    /// platform.
    HostHighPrec = 2,
    /// The timestamp is a high-precision time stamp supplied by the capture device.
    ///
    /// The timestamp is synchronized with the system clock.
    Adapter = 3,
    /// The timestamp is a high-precision time stamp supplied by the capture device.
    ///
    /// The timestamp is not synchronized with the system clock.
    AdapterUnsynced = 4,
}

#[cfg(test)]
mod tests {
    use crate::{
        capture::testmod::test_capture,
        raw::testmod::{as_pcap_t, geterr_expect, RAWMTX},
    };

    use super::*;

    #[test]
    fn test_from_device() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let ctx = raw::pcap_create_context();
        ctx.expect().return_once_st(move |_, _| pcap);

        let ctx = raw::pcap_close_context();
        ctx.expect()
            .withf_st(move |ptr| *ptr == pcap)
            .return_once(|_| {});

        let result = Capture::from_device("some_device");
        assert!(result.is_ok());
    }

    #[test]
    fn test_from_device_error() {
        let _m = RAWMTX.lock();

        let ctx = raw::pcap_create_context();
        ctx.expect().return_once_st(|_, _| std::ptr::null_mut());

        let result = Capture::from_device("some_device");
        assert!(result.is_err());
    }

    #[test]
    fn test_open() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_activate_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap)
            .return_once(|_| 0);

        let result = capture.open();
        assert!(result.is_ok());
    }

    #[test]
    fn test_open_error() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_activate_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap)
            .return_once(|_| -1);

        let _err = geterr_expect(pcap);

        let result = capture.open();
        assert!(result.is_err());
    }

    #[test]
    fn test_timeout() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_set_timeout_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);

        let _capture = capture.timeout(5);
    }

    #[test]
    #[cfg(libpcap_1_2_1)]
    fn test_timstamp_type() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_set_tstamp_type_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);

        let _capture = capture.tstamp_type(TimestampType::Host);

        // For code coverage of the derive line.
        assert_ne!(TimestampType::Host, TimestampType::HostLowPrec);
        assert_ne!(TimestampType::Host, TimestampType::HostHighPrec);
    }

    #[test]
    fn test_promisc() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_set_promisc_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);

        let _capture = capture.promisc(true);
    }

    #[cfg(libpcap_1_5_0)]
    struct ImmediateModeExpect(raw::__pcap_set_immediate_mode::Context);

    #[cfg(all(windows, not(libpcap_1_5_0)))]
    struct ImmediateModeExpect(raw::__pcap_setmintocopy::Context);

    #[cfg(any(libpcap_1_5_0, windows))]
    fn immediate_mode_expect(pcap: *mut raw::pcap_t) -> ImmediateModeExpect {
        #[cfg(libpcap_1_5_0)]
        {
            let ctx = raw::pcap_set_immediate_mode_context();
            ctx.checkpoint();
            ctx.expect()
                .withf_st(move |arg1, _| *arg1 == pcap)
                .return_once(|_, _| 0);
            ImmediateModeExpect(ctx)
        }
        #[cfg(all(windows, not(libpcap_1_5_0)))]
        {
            let ctx = raw::pcap_setmintocopy_context();
            ctx.checkpoint();
            ctx.expect()
                .withf_st(move |arg1, _| *arg1 == pcap)
                .return_once(|_, _| 0);
            ImmediateModeExpect(ctx)
        }
    }

    #[test]
    #[cfg(any(libpcap_1_5_0, windows))]
    fn test_immediate_mode() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let _ctx = immediate_mode_expect(pcap);
        let capture = capture.immediate_mode(true);

        let _ctx = immediate_mode_expect(pcap);
        let _capture = capture.immediate_mode(false);
    }

    #[test]
    #[cfg(all(libpcap_1_5_3, target_os = "macos"))]
    fn test_want_pktap() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_set_want_pktap_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);
        let _capture = capture.want_pktap(true);
    }

    #[test]
    #[cfg(not(windows))]
    fn test_rfmon() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_set_rfmon_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);

        let _capture = capture.rfmon(true);
    }

    #[test]
    fn test_buffer_size() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_set_buffer_size_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);

        let _capture = capture.buffer_size(10);
    }

    #[test]
    #[cfg(libpcap_1_5_0)]
    fn test_precision() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_set_tstamp_precision_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);

        let _capture = capture.precision(Precision::Nano);
    }

    #[test]
    fn test_snaplen() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Inactive>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_set_snaplen_context();
        ctx.expect()
            .withf_st(move |arg1, _| *arg1 == pcap)
            .return_once(|_, _| 0);

        let _capture = capture.snaplen(10);
    }
}
