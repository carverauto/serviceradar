#[cfg(unix)]
pub mod unix;
#[cfg(unix)]
pub use unix::PacketStream;

#[cfg(windows)]
pub mod windows;
#[cfg(windows)]
pub use windows::PacketStream;

use crate::{
    capture::{Activated, Capture},
    codec::PacketCodec,
    Error,
};

impl<T: Activated + ?Sized> Capture<T> {
    /// Returns this capture as a [`futures::Stream`] of packets.
    ///
    /// # Errors
    ///
    /// If this capture is set to be blocking, or if the network device
    /// does not support `select()`, an error will be returned.
    pub fn stream<C: PacketCodec>(self, codec: C) -> Result<PacketStream<T, C>, Error> {
        if !self.is_nonblock() {
            return Err(Error::NonNonBlock);
        }
        PacketStream::new(self, codec)
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        capture::{testmod::test_capture, Active},
        codec::testmod::Codec,
        raw::testmod::{as_pcap_t, RAWMTX},
    };

    #[test]
    fn test_stream_error() {
        let _m = RAWMTX.lock();

        let mut dummy: isize = 777;
        let pcap = as_pcap_t(&mut dummy);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;
        assert!(!capture.is_nonblock());

        let result = capture.stream(Codec);
        assert!(result.is_err());
    }
}
