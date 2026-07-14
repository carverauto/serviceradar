use crate::{
    err::{ValueTooBigError, ValueType},
    *,
};

/// Slice containing the TCP header & payload.
#[derive(Clone, Eq, PartialEq)]
pub struct TcpSlice<'a> {
    header_len: usize,
    slice: &'a [u8],
}

impl<'a> TcpSlice<'a> {
    /// Try creating a [`TcpSlice`] from a slice containing the
    /// TCP header and the TCP payload.
    pub fn from_slice(slice: &'a [u8]) -> Result<TcpSlice<'a>, err::tcp::HeaderSliceError> {
        use err::tcp::{HeaderError::*, HeaderSliceError::*};

        // check length
        if slice.len() < TcpHeader::MIN_LEN {
            return Err(Len(err::LenError {
                required_len: TcpHeader::MIN_LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::TcpHeader,
                layer_start_offset: 0,
            }));
        }

        // SAFETY:
        // Safe as it is checked at the start of the function that the
        // length of the slice is at least TcpHeader::MIN_LEN (20).
        let header_len = unsafe {
            // The length of the TCP header can be determined via
            // the data offset field of the TCP header. "data offset"
            // stores the offset in 4 byte steps from the start of the
            // header to the payload of the header.
            //
            // "data offset" is stored in the upper 4 bits
            // (aka 0b1111_0000) of byte 12. To get to total length
            // in bytes of the header data offset has to be multiplied
            // by 4. So the naive version to get the length of
            // the header would be:
            //
            // ```
            // let data_offset = (*slice.get_unchecked(12) & 0xf0) >> 4;
            // let len = data_offset * 4;
            // ```
            //
            // But a multiplication by 4 can be replaced by 2
            // left shift:
            //
            // ```
            // let data_offset = (*slice.get_unchecked(12) & 0xf0) >> 4;
            // let len = data_offset << 2;
            // ```
            //
            // And finally the shifts can be combined to one:
            //
            // ```
            // let len = (*slice.get_unchecked(12) & 0xf0) >> 2;
            // ```
            usize::from((*slice.get_unchecked(12) & 0xf0) >> 2)
        };

        if header_len < TcpHeader::MIN_LEN {
            Err(Content(DataOffsetTooSmall {
                data_offset: (header_len >> 2) as u8,
            }))
        } else if slice.len() < header_len {
            Err(Len(err::LenError {
                required_len: header_len,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::TcpHeader,
                layer_start_offset: 0,
            }))
        } else {
            //done
            Ok(TcpSlice::<'a> { header_len, slice })
        }
    }

    /// Returns the slice containing the TCP header and payload.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns the slice containing the TCP header
    /// (including options).
    #[inline]
    pub fn header_slice(&self) -> &'a [u8] {
        unsafe {
            // SAFETY: Safe as the slice was verified
            // to be at least header_len long.
            core::slice::from_raw_parts(self.slice.as_ptr(), self.header_len)
        }
    }

    /// Returns the slice containing the TCP payload.
    #[inline]
    pub fn payload(&self) -> &'a [u8] {
        unsafe {
            // SAFETY: Safe as the slice was verified
            // to be at least header_len long.
            core::slice::from_raw_parts(
                self.slice.as_ptr().add(self.header_len),
                self.slice.len() - self.header_len,
            )
        }
    }

    /// Length of the TCP header (including TCP options).
    #[inline]
    pub const fn header_len(&self) -> usize {
        self.header_len
    }

    /// Read the destination port number in the TCP header.
    #[inline]
    pub fn source_port(&self) -> u16 {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { get_unchecked_be_u16(self.slice.as_ptr()) }
    }

    /// Read the destination port number in the TCP header.
    #[inline]
    pub fn destination_port(&self) -> u16 {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(2)) }
    }

    /// Read the sequence number in the TCP header.
    ///
    /// If SYN is present the sequence number is the initial sequence number (ISN)
    /// and the first data octet is ISN+1.
    /// \[copied from RFC 793, page 16\]
    #[inline]
    pub fn sequence_number(&self) -> u32 {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { get_unchecked_be_u32(self.slice.as_ptr().add(4)) }
    }

    /// Reads the acknowledgment number in the TCP header.
    ///
    /// If the ACK control bit is set this field contains the value of the
    /// next sequence number the sender of the segment is expecting to
    /// receive.
    ///
    /// Once a connection is established this is always sent.
    #[inline]
    pub fn acknowledgment_number(&self) -> u32 {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { get_unchecked_be_u32(self.slice.as_ptr().add(8)) }
    }

    /// Read the number of 32 bit words in the TCP Header.
    ///
    /// This indicates where the payload begins. The TCP header
    /// (even one including options) is an integral number of 32
    /// bits long.
    #[inline]
    pub fn data_offset(&self) -> u8 {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { (*self.slice.get_unchecked(12) & 0b1111_0000) >> 4 }
    }

    /// ECN-nonce - concealment protection (experimental: see RFC 3540)
    #[inline]
    pub fn ns(&self) -> bool {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { 0 != (*self.slice.get_unchecked(12) & 0b0000_0001) }
    }

    /// Read the fin flag (no more data from sender).
    #[inline]
    pub fn fin(&self) -> bool {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { 0 != (*self.slice.get_unchecked(13) & 0b0000_0001) }
    }

    /// Reads the syn flag (synchronize sequence numbers).
    #[inline]
    pub fn syn(&self) -> bool {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { 0 != (*self.slice.get_unchecked(13) & 0b0000_0010) }
    }

    /// Reads the rst flag (reset the connection).
    #[inline]
    pub fn rst(&self) -> bool {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { 0 != (*self.slice.get_unchecked(13) & 0b0000_0100) }
    }

    /// Reads the psh flag (push function).
    #[inline]
    pub fn psh(&self) -> bool {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { 0 != (*self.slice.get_unchecked(13) & 0b0000_1000) }
    }

    /// Reads the ack flag (acknowledgment field significant).
    #[inline]
    pub fn ack(&self) -> bool {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { 0 != (*self.slice.get_unchecked(13) & 0b0001_0000) }
    }

    /// Reads the urg flag (Urgent Pointer field significant).
    #[inline]
    pub fn urg(&self) -> bool {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { 0 != (*self.slice.get_unchecked(13) & 0b0010_0000) }
    }

    /// Read the ECN-Echo flag (RFC 3168).
    #[inline]
    pub fn ece(&self) -> bool {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { 0 != (*self.slice.get_unchecked(13) & 0b0100_0000) }
    }

    /// Reads the cwr flag (Congestion Window Reduced).
    ///
    /// This flag is set by the sending host to indicate that it received a TCP
    /// segment with the ECE flag set and had responded in congestion control
    /// mechanism (added to header by RFC 3168).
    #[inline]
    pub fn cwr(&self) -> bool {
        // SAFETY:
        // Constructor checks that the slice has at least the length
        // of 20.
        unsafe { 0 != (*self.slice.get_unchecked(13) & 0b1000_0000) }
    }

    /// The number of data octets beginning with the one indicated in the
    /// acknowledgment field which the sender of this segment is willing to
    /// accept.
    #[inline]
    pub fn window_size(&self) -> u16 {
        u16::from_be_bytes(
            // SAFETY:
            // Constructor checks that the slice has at least the length
            // of 20.
            unsafe { [*self.slice.get_unchecked(14), *self.slice.get_unchecked(15)] },
        )
    }

    /// Checksum (16 bit one's complement) of the pseudo ip header, this tcp header and the payload.
    #[inline]
    pub fn checksum(&self) -> u16 {
        u16::from_be_bytes(
            // SAFETY:
            // Constructor checks that the slice has at least the length
            // of 20.
            unsafe { [*self.slice.get_unchecked(16), *self.slice.get_unchecked(17)] },
        )
    }

    /// This field communicates the current value of the urgent pointer as a
    /// positive offset from the sequence number in this segment.
    ///
    /// The urgent pointer points to the sequence number of the octet following
    /// the urgent data.  This field is only be interpreted in segments with
    /// the URG control bit set.
    #[inline]
    pub fn urgent_pointer(&self) -> u16 {
        u16::from_be_bytes(
            // SAFETY:
            // Constructor checks that the slice has at least the length
            // of 20.
            unsafe { [*self.slice.get_unchecked(18), *self.slice.get_unchecked(19)] },
        )
    }

    /// Options of the header
    #[inline]
    pub fn options(&self) -> &[u8] {
        &self.slice[TcpHeader::MIN_LEN..self.header_len]
    }

    /// Returns an iterator that allows to iterate through all known TCP header options.
    #[inline]
    pub fn options_iterator(&self) -> TcpOptionsIterator<'_> {
        TcpOptionsIterator::from_slice(self.options())
    }

    /// Decode all the fields and copy the results to a
    /// [`crate::TcpHeader`]` struct.
    pub fn to_header(&self) -> TcpHeader {
        TcpHeader {
            source_port: self.source_port(),
            destination_port: self.destination_port(),
            sequence_number: self.sequence_number(),
            acknowledgment_number: self.acknowledgment_number(),
            ns: self.ns(),
            fin: self.fin(),
            syn: self.syn(),
            rst: self.rst(),
            psh: self.psh(),
            ack: self.ack(),
            ece: self.ece(),
            urg: self.urg(),
            cwr: self.cwr(),
            window_size: self.window_size(),
            checksum: self.checksum(),
            urgent_pointer: self.urgent_pointer(),
            options: {
                let options_slice = self.options();
                let mut options = TcpOptions {
                    len: options_slice.len() as u8,
                    buf: [0; 40],
                };
                options.buf[..options_slice.len()].clone_from_slice(options_slice);
                options
            },
        }
    }

    /// Calculates the checksum for the current header in ipv4 mode and
    /// returns the result. This does NOT set the checksum.
    pub fn calc_checksum_ipv4(
        &self,
        source_ip: [u8; 4],
        destination_ip: [u8; 4],
    ) -> Result<u16, ValueTooBigError<usize>> {
        // check that the total length fits into the field
        if usize::from(u16::MAX) < self.slice.len() {
            return Err(ValueTooBigError {
                actual: self.slice.len(),
                max_allowed: usize::from(u16::MAX),
                value_type: ValueType::TcpPayloadLengthIpv4,
            });
        }

        // calculate the checksum
        Ok(self.calc_checksum_post_ip(
            checksum::Sum16BitWords::new()
                .add_4bytes(source_ip)
                .add_4bytes(destination_ip)
                .add_2bytes([0, ip_number::TCP.0])
                .add_2bytes((self.slice.len() as u16).to_be_bytes()),
        ))
    }

    /// Calculates the checksum for the current header in ipv6 mode and
    /// returns the result. This does NOT set the checksum.
    pub fn calc_checksum_ipv6(
        &self,
        source: [u8; 16],
        destination: [u8; 16],
    ) -> Result<u16, ValueTooBigError<usize>> {
        // check that the total length fits into the field
        #[cfg(not(any(target_pointer_width = "16", target_pointer_width = "32")))]
        if (u32::MAX as usize) < self.slice.len() {
            return Err(ValueTooBigError {
                actual: self.slice.len(),
                max_allowed: (u32::MAX as usize),
                value_type: ValueType::TcpPayloadLengthIpv6,
            });
        }

        // calculate the checksum
        Ok(self.calc_checksum_post_ip(
            checksum::Sum16BitWords::new()
                .add_16bytes(source)
                .add_16bytes(destination)
                .add_2bytes([0, ip_number::TCP.0])
                .add_4bytes((self.slice.len() as u32).to_be_bytes()),
        ))
    }

    /// This method takes the sum of the pseudo ip header and calculates the rest of the checksum.
    fn calc_checksum_post_ip(&self, ip_pseudo_header_sum: checksum::Sum16BitWords) -> u16 {
        ip_pseudo_header_sum
            .add_slice(&self.slice[..16]) //until checksum
            .add_slice(&self.slice[18..])
            .ones_complement()
            .to_be()
    }
}

impl core::fmt::Debug for TcpSlice<'_> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("TcpSlice")
            .field("header", &self.to_header())
            .field("payload", &self.payload())
            .finish()
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::*;
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn debug_clone_eq(
            tcp in tcp_any()
        ) {
            let payload: [u8;4] = [1,2,3,4];
            let mut data = Vec::with_capacity(
                tcp.header_len() as usize +
                payload.len()
            );
            data.extend_from_slice(&tcp.to_bytes());
            data.extend_from_slice(&payload);

            // decode packet
            let slice = TcpSlice::from_slice(&data).unwrap();

            // check debug output
            prop_assert_eq!(
                format!("{:?}", slice),
                format!(
                    "TcpSlice {{ header: {:?}, payload: {:?} }}",
                    &tcp,
                    &payload[..]
                )
            );
            prop_assert_eq!(slice.clone(), slice);
        }
    }

    proptest! {
        #[test]
        fn from_slice(
            tcp in tcp_any()
        ) {
            use err::tcp::{HeaderError::*, HeaderSliceError::*};

            let payload: [u8;4] = [1,2,3,4];
            let data = {
                let mut data = Vec::with_capacity(
                    tcp.header_len() as usize +
                    payload.len()
                );
                data.extend_from_slice(&tcp.to_bytes());
                data.extend_from_slice(&payload);
                data
            };

            // normal decode
            {
                let slice = TcpSlice::from_slice(&data).unwrap();
                assert_eq!(&slice.to_header(), &tcp);
                assert_eq!(slice.payload(), &payload);
            }

            // too little data to even decode the header
            for len in 0..(tcp.header_len() as usize) {
                assert_eq!(
                    TcpSlice::from_slice(&data[..len]).unwrap_err(),
                    Len(err::LenError {
                        required_len: if len < TcpHeader::MIN_LEN {
                            TcpHeader::MIN_LEN
                        } else {
                            tcp.header_len()
                        },
                        len,
                        len_source: LenSource::Slice,
                        layer: err::Layer::TcpHeader,
                        layer_start_offset: 0,
                    })
                );
            }

            // data offset smaller then minimum header size
            {
                let mut broken_data = data.clone();
                for data_offset in 0..TcpHeader::MIN_DATA_OFFSET {
                    // inject a bad data offset
                    broken_data[12] = data_offset << 4 | ( broken_data[12] & 0b0000_1111);
                    assert_eq!(
                        TcpSlice::from_slice(&broken_data).unwrap_err(),
                        Content(DataOffsetTooSmall { data_offset })
                    );
                }
            }
        }
    }

    proptest! {
        #[test]
        fn getters(
            tcp in tcp_any()
        ) {
            let payload: [u8;4] = [1,2,3,4];
            let data = {
                let mut data = Vec::with_capacity(
                    tcp.header_len() as usize +
                    payload.len()
                );
                data.extend_from_slice(&tcp.to_bytes());
                data.extend_from_slice(&payload);
                data
            };
            let slice = TcpSlice::from_slice(&data).unwrap();
            assert_eq!(slice.slice(), &data);
            assert_eq!(slice.header_slice(), &data[..tcp.header_len()]);
            assert_eq!(slice.payload(), &data[tcp.header_len()..]);
            assert_eq!(slice.header_len(), tcp.header_len());
            assert_eq!(slice.source_port(), tcp.source_port);
            assert_eq!(slice.destination_port(), tcp.destination_port);
            assert_eq!(slice.sequence_number(), tcp.sequence_number);
            assert_eq!(slice.acknowledgment_number(), tcp.acknowledgment_number);
            assert_eq!(slice.data_offset(), tcp.data_offset());
            assert_eq!(slice.ns(), tcp.ns);
            assert_eq!(slice.fin(), tcp.fin);
            assert_eq!(slice.syn(), tcp.syn);
            assert_eq!(slice.rst(), tcp.rst);
            assert_eq!(slice.psh(), tcp.psh);
            assert_eq!(slice.ack(), tcp.ack);
            assert_eq!(slice.urg(), tcp.urg);
            assert_eq!(slice.ece(), tcp.ece);
            assert_eq!(slice.cwr(), tcp.cwr);
            assert_eq!(slice.window_size(), tcp.window_size);
            assert_eq!(slice.checksum(), tcp.checksum);
            assert_eq!(slice.urgent_pointer(), tcp.urgent_pointer);
            assert_eq!(slice.options(), tcp.options.as_slice());
            assert_eq!(slice.options_iterator(), tcp.options_iterator());
            assert_eq!(slice.to_header(), tcp);
        }
    }

    #[test]
    fn calc_checksum_ipv4() {
        use TcpOptionElement::*;

        // checksum == 0xf (no carries) (aka sum == 0xffff)
        {
            let payload = [1, 2, 3, 4, 5, 6, 7, 8];
            let tcp = TcpHeader::new(0, 0, 40905, 0);

            let mut data = Vec::with_capacity(tcp.header_len() + payload.len());
            data.extend_from_slice(&tcp.to_bytes());
            data.extend_from_slice(&payload);

            let tcp_slice = TcpSlice::from_slice(&data).unwrap();
            assert_eq!(Ok(0x0), tcp_slice.calc_checksum_ipv4([0; 4], [0; 4]));
        }

        // a header with options
        {
            let payload = [1, 2, 3, 4, 5, 6, 7, 8];
            let mut tcp = TcpHeader::new(69, 42, 0x24900448, 0x3653);
            tcp.urgent_pointer = 0xE26E;
            tcp.ns = true;
            tcp.fin = true;
            tcp.syn = true;
            tcp.rst = true;
            tcp.psh = true;
            tcp.ack = true;
            tcp.ece = true;
            tcp.urg = true;
            tcp.cwr = true;
            tcp.set_options(&[Noop, Noop, Noop, Noop, Timestamp(0x4161008, 0x84161708)])
                .unwrap();

            let mut data = Vec::with_capacity(tcp.header_len() + payload.len());
            data.extend_from_slice(&tcp.to_bytes());
            data.extend_from_slice(&payload);

            let tcp_slice = TcpSlice::from_slice(&data).unwrap();

            assert_eq!(
                Ok(0xdeeb),
                tcp_slice.calc_checksum_ipv4([192, 168, 1, 42], [192, 168, 1, 1])
            );
        }

        //a header with an uneven number of options
        {
            let payload = [1, 2, 3, 4, 5, 6, 7, 8, 9];
            let mut tcp = TcpHeader::new(69, 42, 0x24900448, 0x3653);
            tcp.urgent_pointer = 0xE26E;
            tcp.ns = true;
            tcp.fin = true;
            tcp.syn = true;
            tcp.rst = true;
            tcp.psh = true;
            tcp.ack = true;
            tcp.ece = true;
            tcp.urg = true;
            tcp.cwr = true;
            tcp.set_options(&[Noop, Noop, Noop, Noop, Timestamp(0x4161008, 0x84161708)])
                .unwrap();

            let mut data = Vec::with_capacity(tcp.header_len() + payload.len());
            data.extend_from_slice(&tcp.to_bytes());
            data.extend_from_slice(&payload);

            let slice = TcpSlice::from_slice(&data[..]).unwrap();

            assert_eq!(
                Ok(0xd5ea),
                slice.calc_checksum_ipv4([192, 168, 1, 42], [192, 168, 1, 1])
            );
        }

        // value error
        {
            // write the tcp header
            let tcp: TcpHeader = Default::default();
            let mut data = Vec::with_capacity(usize::from(core::u16::MAX) + 1);
            data.extend_from_slice(&tcp.to_bytes());
            data.resize(usize::from(core::u16::MAX) + 1, 0); // payload

            let slice = TcpSlice::from_slice(&data).unwrap();

            assert_eq!(
                slice.calc_checksum_ipv4([0; 4], [0; 4]),
                Err(ValueTooBigError {
                    actual: data.len(),
                    max_allowed: usize::from(core::u16::MAX),
                    value_type: ValueType::TcpPayloadLengthIpv4,
                })
            );
        }
    }

    #[test]
    fn calc_checksum_ipv6() {
        use crate::TcpOptionElement::*;

        // ok case
        {
            let payload = [51, 52, 53, 54, 55, 56, 57, 58];
            let mut tcp = TcpHeader::new(69, 42, 0x24900448, 0x3653);
            tcp.urgent_pointer = 0xE26E;
            tcp.ns = true;
            tcp.fin = true;
            tcp.syn = true;
            tcp.rst = true;
            tcp.psh = true;
            tcp.ack = true;
            tcp.ece = true;
            tcp.urg = true;
            tcp.cwr = true;
            tcp.set_options(&[Noop, Noop, Noop, Noop, Timestamp(0x4161008, 0x84161708)])
                .unwrap();

            let mut data = Vec::with_capacity(tcp.header_len() + payload.len());
            data.extend_from_slice(&tcp.to_bytes());
            data.extend_from_slice(&payload);

            let slice = TcpSlice::from_slice(&data).unwrap();
            assert_eq!(
                Ok(0x786e),
                slice.calc_checksum_ipv6(
                    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
                    [21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36,],
                )
            );
        }

        // error
        #[cfg(target_pointer_width = "64")]
        {
            let slice = TcpSlice {
                header_len: TcpHeader::MIN_LEN,
                // lets create a slice of that size that points to zero
                // (as most systems can not allocate blocks of the size of u32::MAX)
                slice: unsafe {
                    //NOTE: The pointer must be initialized with a non null value
                    //      otherwise a key constraint of slices is not fulfilled
                    //      which can lead to crashes in release mode.
                    use core::ptr::NonNull;
                    core::slice::from_raw_parts(
                        NonNull::<u8>::dangling().as_ptr(),
                        (core::u32::MAX as usize) + 1,
                    )
                },
            };

            // expect an length error
            assert_eq!(
                slice.calc_checksum_ipv6(
                    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
                    [21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36,],
                ),
                Err(ValueTooBigError {
                    actual: (core::u32::MAX as usize) + 1,
                    max_allowed: core::u32::MAX as usize,
                    value_type: ValueType::TcpPayloadLengthIpv6,
                })
            );
        }
    }
}
