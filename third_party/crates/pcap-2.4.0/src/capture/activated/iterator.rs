use crate::{
    capture::{Activated, Capture},
    codec::PacketCodec,
    Error,
};

/// Implement an Iterator of Packet
pub struct PacketIter<S: Activated + ?Sized, C> {
    capture: Capture<S>,
    codec: C,
}

impl<S: Activated + ?Sized, C> PacketIter<S, C> {
    pub(crate) fn new(capture: Capture<S>, codec: C) -> Self {
        Self { capture, codec }
    }

    /// Returns a mutable reference to the inner [`Capture`].
    pub fn capture_mut(&mut self) -> &mut Capture<S> {
        &mut self.capture
    }
}

impl<S: Activated + ?Sized, C> From<PacketIter<S, C>> for (Capture<S>, C) {
    fn from(iter: PacketIter<S, C>) -> Self {
        (iter.capture, iter.codec)
    }
}

impl<S: Activated + ?Sized, C: PacketCodec> Iterator for PacketIter<S, C> {
    type Item = Result<C::Item, Error>;

    fn next(&mut self) -> Option<Self::Item> {
        match self.capture.next_packet() {
            Ok(packet) => Some(Ok(self.codec.decode(packet))),
            Err(Error::NoMorePackets) => None,
            Err(e) => Some(Err(e)),
        }
    }
}

#[cfg(feature = "lending-iter")]
mod lending_iter {
    use crate::Activated;
    use crate::Capture;
    use crate::Error;
    use crate::Packet;
    use gat_std::iter::{IntoIterator, Iterator};

    pub struct PacketLendingIter<S: Activated + ?Sized> {
        capture: Capture<S>,
    }

    impl<S: Activated + ?Sized + 'static> IntoIterator for Capture<S> {
        type IntoIter = PacketLendingIter<S>;

        fn into_iter(self) -> Self::IntoIter {
            PacketLendingIter { capture: self }
        }
    }

    impl<S: Activated + ?Sized + 'static> Iterator for PacketLendingIter<S> {
        type Item<'a> = Result<Packet<'a>, Error>;

        fn next(&mut self) -> Option<Self::Item<'_>> {
            match self.capture.next_packet() {
                Ok(packet) => Some(Ok(packet)),
                Err(Error::NoMorePackets) => None,
                Err(e) => Some(Err(e)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        capture::{
            activated::testmod::{next_ex_expect, PACKET},
            testmod::test_capture,
            Active, Offline,
        },
        codec::testmod::Codec,
        raw::{
            self,
            testmod::{as_pcap_t, geterr_expect, RAWMTX},
        },
    };

    #[cfg(feature = "lending-iter")]
    use gat_std::iter::{IntoIterator, Iterator};

    use super::*;

    #[cfg(feature = "lending-iter")]
    use super::lending_iter::*;

    #[test]
    fn test_iter_next() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;
        let mut packet_iter = capture.iter(Codec);

        let _nxt = next_ex_expect(pcap);

        let next = packet_iter.next().unwrap();
        let next_packet = next.unwrap();
        assert_eq!(next_packet.header, *PACKET.header);
        assert_eq!(*next_packet.data, *PACKET.data);

        let _nxt = next_ex_expect(pcap);

        let next_packet = packet_iter.capture_mut().next_packet().unwrap();
        assert_eq!(next_packet, PACKET);

        let _nxt = next_ex_expect(pcap);

        let (mut capture, _) = packet_iter.into();

        let next_packet = capture.next_packet().unwrap();
        assert_eq!(next_packet, PACKET);
    }

    #[test]
    fn test_iter_timeout() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;

        let mut packet_iter = capture.iter(Codec);

        let ctx = raw::pcap_next_ex_context();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap)
            .return_once_st(move |_, _, _| 0);

        let next = packet_iter.next().unwrap();
        let err = next.unwrap_err();
        assert_eq!(err, Error::TimeoutExpired);
    }

    #[test]
    fn test_next_packet_read_error() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;

        let mut packet_iter = capture.iter(Codec);

        let ctx = raw::pcap_next_ex_context();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap)
            .return_once_st(move |_, _, _| -1);

        let _err = geterr_expect(pcap);

        let next = packet_iter.next().unwrap();
        assert!(next.is_err());
    }

    #[test]
    fn test_next_packet_no_more_packets() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Offline>(pcap);
        let capture = test_capture.capture;

        let mut packet_iter = capture.iter(Codec);

        let ctx = raw::pcap_next_ex_context();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap)
            .return_once_st(move |_, _, _| -2);

        let next = packet_iter.next();
        assert!(next.is_none());
    }

    #[test]
    #[cfg(feature = "lending-iter")]
    fn test_lending_iter() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;
        let mut packet_iter: PacketLendingIter<Active> = capture.into_iter();

        let _nxt = next_ex_expect(pcap);

        let next = packet_iter.next().unwrap();
        let next_packet = next.unwrap();
        assert_eq!(next_packet, PACKET);
    }

    #[test]
    #[cfg(feature = "lending-iter")]
    fn test_lending_iter_timeout() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;
        let mut packet_iter: PacketLendingIter<Active> = capture.into_iter();

        let ctx = raw::pcap_next_ex_context();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap)
            .return_once_st(move |_, _, _| 0);

        let next = packet_iter.next().unwrap();
        let err = next.unwrap_err();
        assert_eq!(err, Error::TimeoutExpired);
    }

    #[test]
    #[cfg(feature = "lending-iter")]
    fn test_lending_iter_read_error() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Active>(pcap);
        let capture = test_capture.capture;
        let mut packet_iter: PacketLendingIter<Active> = capture.into_iter();

        let ctx = raw::pcap_next_ex_context();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap)
            .return_once_st(move |_, _, _| -1);

        let _err = geterr_expect(pcap);

        let next = packet_iter.next().unwrap();
        assert!(next.is_err());
    }

    #[test]
    #[cfg(feature = "lending-iter")]
    fn test_lending_iter_no_more_packets() {
        let _m = RAWMTX.lock();

        let mut value: isize = 777;
        let pcap = as_pcap_t(&mut value);

        let test_capture = test_capture::<Offline>(pcap);
        let capture = test_capture.capture;
        let mut packet_iter: PacketLendingIter<Offline> = capture.into_iter();

        let ctx = raw::pcap_next_ex_context();
        ctx.expect()
            .withf_st(move |arg1, _, _| *arg1 == pcap)
            .return_once_st(move |_, _, _| -2);

        let next = packet_iter.next();
        assert!(next.is_none());
    }
}
