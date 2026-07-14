use std::os::unix::io::{AsRawFd, RawFd};

use crate::{
    capture::{Activated, Capture, State},
    raw, Error,
};

/// Newtype [`Capture`] wrapper that exposes `pcap_get_selectable_fd()`.
pub struct SelectableCapture<T: State + ?Sized> {
    inner: Capture<T>,
    fd: RawFd,
}

impl<T: Activated + ?Sized> SelectableCapture<T> {
    pub fn new(capture: Capture<T>) -> Result<Self, Error> {
        let fd = unsafe { raw::pcap_get_selectable_fd(capture.as_ptr()) };
        if fd == -1 {
            return Err(Error::InvalidRawFd);
        }
        Ok(Self { inner: capture, fd })
    }

    pub fn get_inner_mut(&mut self) -> &mut Capture<T> {
        &mut self.inner
    }
}

impl<T: Activated + ?Sized> AsRawFd for SelectableCapture<T> {
    fn as_raw_fd(&self) -> RawFd {
        self.fd
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        capture::{testmod::test_capture, Active},
        raw::testmod::{as_pcap_t, RAWMTX},
    };

    use super::*;

    #[test]
    fn test_selectable_capture() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_get_selectable_fd_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap)
            .return_once(|_| 5);

        let mut selectable = SelectableCapture::new(capture).unwrap();
        assert!(!selectable.get_inner_mut().is_nonblock());
        assert_eq!(selectable.as_raw_fd(), 5);
    }

    #[test]
    fn test_selectable_capture_error() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;

        let ctx = raw::pcap_get_selectable_fd_context();
        ctx.expect()
            .withf_st(move |arg1| *arg1 == pcap)
            .return_once(|_| -1);

        let result = SelectableCapture::new(capture);
        assert!(result.is_err());
    }
}
