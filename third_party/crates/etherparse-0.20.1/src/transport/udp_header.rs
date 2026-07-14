use crate::{err::ValueTooBigError, *};

/// Udp header according to rfc768.
#[derive(Clone, Debug, Eq, PartialEq, Hash, Default, PartialOrd, Ord)]
pub struct UdpHeader {
    /// Source port of the packet (optional).
    pub source_port: u16,
    /// Destination port of the packet.
    pub destination_port: u16,
    /// Length of the packet (includes the udp header length of 8 bytes).
    pub length: u16,
    /// The checksum of the packet. The checksum is calculated from a pseudo header, the udp header and the payload. The pseudo header is composed of source and destination address, protocol number
    pub checksum: u16,
}

impl UdpHeader {
    /// Serialized size of an UDP header in bytes/octets.
    pub const LEN: usize = 8;

    /// Serialized size of an UDP header in bytes/octets in an [`u16`].
    pub const LEN_U16: u16 = 8;

    #[deprecated(since = "0.14.0", note = "Use `UdpHeader::LEN` instead")]
    pub const SERIALIZED_SIZE: usize = UdpHeader::LEN;

    /// Returns an udp header for the given parameters
    pub fn without_ipv4_checksum(
        source_port: u16,
        destination_port: u16,
        payload_length: usize,
    ) -> Result<UdpHeader, ValueTooBigError<usize>> {
        // check that the total length fits into the field
        const MAX_PAYLOAD_LENGTH: usize = (u16::MAX as usize) - UdpHeader::LEN;
        if MAX_PAYLOAD_LENGTH < payload_length {
            return Err(ValueTooBigError {
                actual: payload_length,
                max_allowed: MAX_PAYLOAD_LENGTH,
                value_type: err::ValueType::UdpPayloadLengthIpv4,
            });
        }

        Ok(UdpHeader {
            source_port,
            destination_port,
            length: (UdpHeader::LEN + payload_length) as u16, //payload plus udp header
            checksum: 0,
        })
    }

    /// Calculate an udp header given an ipv4 header and the payload
    pub fn with_ipv4_checksum(
        source_port: u16,
        destination_port: u16,
        ip_header: &Ipv4Header,
        payload: &[u8],
    ) -> Result<UdpHeader, ValueTooBigError<usize>> {
        // check that the total length fits into the field
        const MAX_PAYLOAD_LENGTH: usize = (u16::MAX as usize) - UdpHeader::LEN;
        if MAX_PAYLOAD_LENGTH < payload.len() {
            return Err(ValueTooBigError {
                actual: payload.len(),
                max_allowed: MAX_PAYLOAD_LENGTH,
                value_type: err::ValueType::UdpPayloadLengthIpv4,
            });
        }

        let mut result = UdpHeader {
            source_port,
            destination_port,
            length: (UdpHeader::LEN + payload.len()) as u16, //payload plus udp header
            checksum: 0,
        };
        result.checksum =
            result.calc_checksum_ipv4_internal(ip_header.source, ip_header.destination, payload);
        Ok(result)
    }

    /// Calculates the upd header checksum based on a ipv4 header.
    pub fn calc_checksum_ipv4(
        &self,
        ip_header: &Ipv4Header,
        payload: &[u8],
    ) -> Result<u16, ValueTooBigError<usize>> {
        self.calc_checksum_ipv4_raw(ip_header.source, ip_header.destination, payload)
    }

    /// Calculates the upd header checksum based on a ipv4 header.
    pub fn calc_checksum_ipv4_raw(
        &self,
        source: [u8; 4],
        destination: [u8; 4],
        payload: &[u8],
    ) -> Result<u16, ValueTooBigError<usize>> {
        // check that the total length fits into the field
        const MAX_PAYLOAD_LENGTH: usize = (u16::MAX as usize) - UdpHeader::LEN;
        if MAX_PAYLOAD_LENGTH < payload.len() {
            return Err(ValueTooBigError {
                actual: payload.len(),
                max_allowed: MAX_PAYLOAD_LENGTH,
                value_type: err::ValueType::UdpPayloadLengthIpv4,
            });
        }

        Ok(self.calc_checksum_ipv4_internal(source, destination, payload))
    }

    /// Calculates the upd header checksum based on a ipv4 header.
    fn calc_checksum_ipv4_internal(
        &self,
        source: [u8; 4],
        destination: [u8; 4],
        payload: &[u8],
    ) -> u16 {
        self.calc_checksum_post_ip(
            //pseudo header
            checksum::Sum16BitWords::new()
                .add_4bytes(source)
                .add_4bytes(destination)
                .add_2bytes([0, ip_number::UDP.0])
                .add_2bytes(self.length.to_be_bytes()),
            payload,
        )
    }

    /// Calculate an udp header given an ipv6 header and the payload
    pub fn with_ipv6_checksum(
        source_port: u16,
        destination_port: u16,
        ip_header: &Ipv6Header,
        payload: &[u8],
    ) -> Result<UdpHeader, ValueTooBigError<usize>> {
        // check that the total length fits into the field
        const MAX_PAYLOAD_LENGTH: usize = (u16::MAX as usize) - UdpHeader::LEN;
        if MAX_PAYLOAD_LENGTH < payload.len() {
            return Err(ValueTooBigError {
                actual: payload.len(),
                max_allowed: MAX_PAYLOAD_LENGTH,
                value_type: err::ValueType::UdpPayloadLengthIpv6,
            });
        }

        let mut result = UdpHeader {
            source_port,
            destination_port,
            length: (UdpHeader::LEN + payload.len()) as u16, //payload plus udp header
            checksum: 0,
        };
        result.checksum =
            result.calc_checksum_ipv6_internal(ip_header.source, ip_header.destination, payload);
        Ok(result)
    }

    /// Calculates the checksum of the current udp header given an ipv6 header and the payload.
    pub fn calc_checksum_ipv6(
        &self,
        ip_header: &Ipv6Header,
        payload: &[u8],
    ) -> Result<u16, err::ValueTooBigError<usize>> {
        self.calc_checksum_ipv6_raw(ip_header.source, ip_header.destination, payload)
    }

    /// Calculates the checksum of the current udp header given an ipv6 source & destination address plus the payload.
    pub fn calc_checksum_ipv6_raw(
        &self,
        source: [u8; 16],
        destination: [u8; 16],
        payload: &[u8],
    ) -> Result<u16, err::ValueTooBigError<usize>> {
        //check that the total length fits into the field
        const MAX_PAYLOAD_LENGTH: usize = (u32::MAX as usize) - UdpHeader::LEN;
        if MAX_PAYLOAD_LENGTH < payload.len() {
            return Err(err::ValueTooBigError {
                actual: payload.len(),
                max_allowed: MAX_PAYLOAD_LENGTH,
                value_type: err::ValueType::UdpPayloadLengthIpv6,
            });
        }

        Ok(self.calc_checksum_ipv6_internal(source, destination, payload))
    }

    fn calc_checksum_ipv6_internal(
        &self,
        source: [u8; 16],
        destination: [u8; 16],
        payload: &[u8],
    ) -> u16 {
        self.calc_checksum_post_ip(
            //pseudo header
            checksum::Sum16BitWords::new()
                .add_16bytes(source)
                .add_16bytes(destination)
                .add_2bytes([0, ip_number::UDP.0])
                .add_2bytes(self.length.to_be_bytes()),
            payload,
        )
    }

    /// This method takes the sum of the pseudo ip header and calculates the rest of the checksum.
    fn calc_checksum_post_ip(
        &self,
        ip_pseudo_header_sum: checksum::Sum16BitWords,
        payload: &[u8],
    ) -> u16 {
        ip_pseudo_header_sum
            .add_2bytes(self.source_port.to_be_bytes())
            .add_2bytes(self.destination_port.to_be_bytes())
            .add_2bytes(self.length.to_be_bytes())
            .add_slice(payload)
            .to_ones_complement_with_no_zero()
            .to_be()
    }

    /// Reads a udp header from a slice directly and returns a tuple containing the resulting header & unused part of the slice.
    #[deprecated(since = "0.10.1", note = "Use UdpHeader::from_slice instead.")]
    #[inline]
    pub fn read_from_slice(slice: &[u8]) -> Result<(UdpHeader, &[u8]), err::LenError> {
        UdpHeader::from_slice(slice)
    }

    /// Reads a udp header from a slice directly and returns a tuple containing the resulting header & unused part of the slice.
    #[inline]
    pub fn from_slice(slice: &[u8]) -> Result<(UdpHeader, &[u8]), err::LenError> {
        Ok((
            UdpHeaderSlice::from_slice(slice)?.to_header(),
            &slice[UdpHeader::LEN..],
        ))
    }

    /// Read an UdpHeader from a static sized byte array.
    #[inline]
    pub fn from_bytes(bytes: [u8; 8]) -> UdpHeader {
        UdpHeader {
            source_port: u16::from_be_bytes([bytes[0], bytes[1]]),
            destination_port: u16::from_be_bytes([bytes[2], bytes[3]]),
            length: u16::from_be_bytes([bytes[4], bytes[5]]),
            checksum: u16::from_be_bytes([bytes[6], bytes[7]]),
        }
    }

    /// Tries to read an udp header from the current position.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
    ) -> Result<UdpHeader, std::io::Error> {
        let bytes = {
            let mut bytes: [u8; 8] = [0; 8];
            reader.read_exact(&mut bytes)?;
            bytes
        };
        Ok(UdpHeader::from_bytes(bytes))
    }

    /// Write the udp header without recalculating the checksum or length.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        writer.write_all(&self.to_bytes())?;
        Ok(())
    }

    /// Length of the serialized header in bytes.
    ///
    /// The function always returns the constant [`crate::UdpHeader::LEN`]
    /// and exists to keep the methods consistent with other headers.
    #[inline]
    pub const fn header_len(&self) -> usize {
        UdpHeader::LEN
    }

    /// Length of the serialized header in bytes in an [`u16`].
    ///
    /// The function always returns the constant [`crate::UdpHeader::LEN_U16`]
    /// and exists to keep the methods consistent with other headers.
    #[inline]
    pub const fn header_len_u16(&self) -> u16 {
        UdpHeader::LEN_U16
    }

    /// Returns the serialized form of the header as a statically
    /// sized byte array.
    #[inline]
    pub fn to_bytes(&self) -> [u8; 8] {
        let source_port_be = self.source_port.to_be_bytes();
        let destination_port_be = self.destination_port.to_be_bytes();
        let length_be = self.length.to_be_bytes();
        let checksum = self.checksum.to_be_bytes();
        [
            source_port_be[0],
            source_port_be[1],
            destination_port_be[0],
            destination_port_be[1],
            length_be[0],
            length_be[1],
            checksum[0],
            checksum[1],
        ]
    }
}

#[cfg(test)]
mod test {
    use crate::{
        err::{ValueTooBigError, ValueType},
        test_gens::*,
        *,
    };
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;
    use std::io::Cursor;

    proptest! {
        #[test]
        fn without_ipv4_checksum(
            source_port in any::<u16>(),
            destination_port in any::<u16>(),
            good_payload_length in 0..=((core::u16::MAX as usize) - UdpHeader::LEN),
            bad_payload_length in ((core::u16::MAX as usize) - UdpHeader::LEN + 1)..=(isize::MAX as usize),
        ) {

            // normal working call
            {
                let actual = UdpHeader::without_ipv4_checksum(
                    source_port,
                    destination_port,
                    good_payload_length
                ).unwrap();
                assert_eq!(
                    actual,
                    UdpHeader{
                        source_port,
                        destination_port,
                        length: (UdpHeader::LEN + good_payload_length) as u16,
                        checksum: 0
                    }
                );
            }

            // length too large
            {
                let actual = UdpHeader::without_ipv4_checksum(
                    source_port,
                    destination_port,
                    bad_payload_length
                ).unwrap_err();
                assert_eq!(
                    actual,
                    ValueTooBigError{
                        actual: bad_payload_length,
                        max_allowed: usize::from(u16::MAX) - UdpHeader::LEN,
                        value_type: err::ValueType::UdpPayloadLengthIpv4,
                    }
                );
            }
        }
    }

    /// Calculat the expected UDP header checksum for the tests.
    fn expected_udp_ipv4_checksum(
        source: [u8; 4],
        destination: [u8; 4],
        udp_header: &UdpHeader,
        payload: &[u8],
    ) -> u16 {
        checksum::Sum16BitWords::new()
            // pseudo header
            .add_4bytes(source)
            .add_4bytes(destination)
            .add_2bytes([0, ip_number::UDP.0])
            .add_2bytes(udp_header.length.to_be_bytes())
            // udp header
            .add_2bytes(udp_header.source_port.to_be_bytes())
            .add_2bytes(udp_header.destination_port.to_be_bytes())
            .add_2bytes(udp_header.length.to_be_bytes())
            .add_2bytes([0, 0]) // checksum as zero (should have no effect)
            .add_slice(payload)
            .to_ones_complement_with_no_zero()
            .to_be()
    }

    proptest! {
        #[test]
        fn with_ipv4_checksum(
            source_port in any::<u16>(),
            destination_port in any::<u16>(),
            ipv4 in ipv4_any(),
            payload in proptest::collection::vec(any::<u8>(), 0..20),
            bad_len in ((core::u16::MAX as usize) - UdpHeader::LEN + 1)..=(isize::MAX as usize),
        ) {
            // normal case
            assert_eq!(
                UdpHeader::with_ipv4_checksum(
                    source_port,
                    destination_port,
                    &ipv4,
                    &payload
                ).unwrap(),
                {
                    let mut expected = UdpHeader {
                        source_port,
                        destination_port,
                        length: (UdpHeader::LEN + payload.len()) as u16,
                        checksum: 0,
                    };
                    let checksum = expected_udp_ipv4_checksum(
                        ipv4.source,
                        ipv4.destination,
                        &expected,
                        &payload
                    );
                    expected.checksum = checksum;
                    expected
                }
            );

            // case where the 16 bit word results in a checksum of
            // 0, but gets converted to 0xffff as 0 is reserved.
            {
                let base = UdpHeader {
                    source_port: 0,
                    destination_port,
                    length: (UdpHeader::LEN + payload.len()) as u16,
                    checksum: 0,
                };
                // use the source port to force 0 as a result value
                // for that first calculate the checksum with the source
                // set to 0
                let sourceless_checksum = !(expected_udp_ipv4_checksum(
                    ipv4.source,
                    ipv4.destination,
                    &base,
                    &payload
                ).to_le());

                assert_eq!(
                    UdpHeader::with_ipv4_checksum(
                        // we now need to add a value that results in the value
                        // 0xffff (which will become 0 via the ones complement rule).
                        0xffff - sourceless_checksum,
                        destination_port,
                        &ipv4,
                        &payload
                    ).unwrap(),
                    UdpHeader{
                        source_port: 0xffff - sourceless_checksum,
                        destination_port,
                        length: base.length,
                        checksum: 0xffff
                    }
                );
            }

            // length error case
            {
                // SAFETY: In case the error is not triggered
                //         a segmentation fault will be triggered.
                let too_big_slice = unsafe {
                    //NOTE: The pointer must be initialized with a non null value
                    //      otherwise a key constraint of slices is not fulfilled
                    //      which can lead to crashes in release mode.
                    use core::ptr::NonNull;
                    core::slice::from_raw_parts(
                        NonNull::<u8>::dangling().as_ptr(),
                        bad_len
                    )
                };
                assert_eq!(
                    UdpHeader::with_ipv4_checksum(
                        source_port,
                        destination_port,
                        &ipv4,
                        &too_big_slice
                    ).unwrap_err(),
                    ValueTooBigError{
                        actual: bad_len,
                        max_allowed: usize::from(u16::MAX) - UdpHeader::LEN,
                        value_type: err::ValueType::UdpPayloadLengthIpv4,
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn calc_checksum_ipv4_raw(
            source_port in any::<u16>(),
            destination_port in any::<u16>(),
            dummy_checksum in any::<u16>(),
            ipv4 in ipv4_any(),
            payload in proptest::collection::vec(any::<u8>(), 0..20),
            bad_len in ((core::u16::MAX as usize) - UdpHeader::LEN + 1)..=(isize::MAX as usize),
        ) {
            // normal case
            {
                let header = UdpHeader {
                    source_port,
                    destination_port,
                    length: (UdpHeader::LEN + payload.len()) as u16,
                    checksum: dummy_checksum,
                };

                assert_eq!(
                    header.calc_checksum_ipv4_raw(
                        ipv4.source,
                        ipv4.destination,
                        &payload
                    ).unwrap(),
                    expected_udp_ipv4_checksum(
                        ipv4.source,
                        ipv4.destination,
                        &header,
                        &payload
                    )
                );
            }

            // case where the 16 bit word results in a checksum of
            // 0, but gets converted to 0xffff as 0 is reserved.
            {
                let base = UdpHeader {
                    source_port: 0,
                    destination_port,
                    length: (UdpHeader::LEN + payload.len()) as u16,
                    checksum: dummy_checksum,
                };
                // use the source port to force 0 as a result value
                // for that first calculate the checksum with the source
                // set to 0
                let sourceless_checksum = !(expected_udp_ipv4_checksum(
                    ipv4.source,
                    ipv4.destination,
                    &base,
                    &payload
                ).to_le());

                // we now need to add a value that results in the value
                // 0xffff (which will become 0 via the ones complement rule).
                let header = {
                    let mut header = base.clone();
                    header.source_port = 0xffff - sourceless_checksum;
                    header
                };

                assert_eq!(
                    0xffff,
                    header.calc_checksum_ipv4_raw(
                        ipv4.source,
                        ipv4.destination,
                        &payload
                    ).unwrap()
                );
            }

            // length error case
            {
                let header = UdpHeader {
                    source_port,
                    destination_port,
                    // udp header length itself is ok, but the payload not
                    length: (UdpHeader::LEN + payload.len()) as u16,
                    checksum: dummy_checksum,
                };
                // SAFETY: In case the error is not triggered
                //         a segmentation fault will be triggered.
                let too_big_slice = unsafe {
                    //NOTE: The pointer must be initialized with a non null value
                    //      otherwise a key constraint of slices is not fulfilled
                    //      which can lead to crashes in release mode.
                    use core::ptr::NonNull;
                    core::slice::from_raw_parts(
                        NonNull::<u8>::dangling().as_ptr(),
                        bad_len
                    )
                };
                assert_eq!(
                    header.calc_checksum_ipv4_raw(
                        ipv4.source,
                        ipv4.destination,
                        too_big_slice
                    ).unwrap_err(),
                    ValueTooBigError{
                        actual: bad_len,
                        max_allowed: (core::u16::MAX as usize) - UdpHeader::LEN,
                        value_type: ValueType::UdpPayloadLengthIpv4,
                    }
                );
            }
        }
    }

    /// Calculat the expected UDP header checksum for the tests.
    fn expected_udp_ipv6_checksum(
        source: [u8; 16],
        destination: [u8; 16],
        udp_header: &UdpHeader,
        payload: &[u8],
    ) -> u16 {
        checksum::Sum16BitWords::new()
            // pseudo header
            .add_16bytes(source)
            .add_16bytes(destination)
            .add_2bytes([0, ip_number::UDP.0])
            .add_4bytes(u32::from(udp_header.length).to_be_bytes())
            // udp header
            .add_2bytes(udp_header.source_port.to_be_bytes())
            .add_2bytes(udp_header.destination_port.to_be_bytes())
            .add_2bytes(udp_header.length.to_be_bytes())
            .add_2bytes([0, 0]) // checksum as zero (should have no effect)
            .add_slice(payload)
            .to_ones_complement_with_no_zero()
            .to_be()
    }

    proptest! {
        #[test]
        fn with_ipv6_checksum(
            source_port in any::<u16>(),
            destination_port in any::<u16>(),
            ipv6 in ipv6_any(),
            payload in proptest::collection::vec(any::<u8>(), 0..20),
            bad_len in ((core::u16::MAX as usize) - UdpHeader::LEN + 1)..=(isize::MAX as usize),
        ) {
            // normal case
            assert_eq!(
                UdpHeader::with_ipv6_checksum(
                    source_port,
                    destination_port,
                    &ipv6,
                    &payload
                ).unwrap(),
                {
                    let mut expected = UdpHeader {
                        source_port,
                        destination_port,
                        length: (UdpHeader::LEN + payload.len()) as u16,
                        checksum: 0,
                    };
                    let checksum = expected_udp_ipv6_checksum(
                        ipv6.source,
                        ipv6.destination,
                        &expected,
                        &payload
                    );
                    expected.checksum = checksum;
                    expected
                }
            );

            // case where the 16 bit word results in a checksum of
            // 0, but gets converted to 0xffff as 0 is reserved.
            {
                let base = UdpHeader {
                    source_port: 0,
                    destination_port,
                    length: (UdpHeader::LEN + payload.len()) as u16,
                    checksum: 0,
                };
                // use the source port to force 0 as a result value
                // for that first calculate the checksum with the source
                // set to 0
                let sourceless_checksum = !(expected_udp_ipv6_checksum(
                    ipv6.source,
                    ipv6.destination,
                    &base,
                    &payload
                ).to_le());

                assert_eq!(
                    UdpHeader::with_ipv6_checksum(
                        // we now need to add a value that results in the value
                        // 0xffff (which will become 0 via the ones complement rule).
                        0xffff - sourceless_checksum,
                        destination_port,
                        &ipv6,
                        &payload
                    ).unwrap(),
                    UdpHeader{
                        source_port: 0xffff - sourceless_checksum,
                        destination_port,
                        length: base.length,
                        checksum: 0xffff
                    }
                );
            }

            // length error case
            {
                // SAFETY: In case the error is not triggered
                //         a segmentation fault will be triggered.
                let too_big_slice = unsafe {
                    //NOTE: The pointer must be initialized with a non null value
                    //      otherwise a key constraint of slices is not fulfilled
                    //      which can lead to crashes in release mode.
                    use core::ptr::NonNull;
                    core::slice::from_raw_parts(
                        NonNull::<u8>::dangling().as_ptr(),
                        bad_len
                    )
                };
                assert_eq!(
                    UdpHeader::with_ipv6_checksum(
                        source_port,
                        destination_port,
                        &ipv6,
                        &too_big_slice
                    ).unwrap_err(),
                    ValueTooBigError{
                        actual: bad_len,
                        max_allowed: usize::from(u16::MAX) - UdpHeader::LEN,
                        value_type: err::ValueType::UdpPayloadLengthIpv6,
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        #[cfg(not(any(target_pointer_width = "16", target_pointer_width = "32")))]
        fn calc_checksum_ipv6(
            source_port in any::<u16>(),
            destination_port in any::<u16>(),
            ipv6 in ipv6_any(),
            payload in proptest::collection::vec(any::<u8>(), 0..20),
            bad_len in ((core::u32::MAX as usize) - UdpHeader::LEN + 1)..=(isize::MAX as usize),
        ) {
            // normal case
            assert_eq!(
                UdpHeader::with_ipv6_checksum(
                    source_port,
                    destination_port,
                    &ipv6,
                    &payload
                ).unwrap(),
                {
                    let mut expected = UdpHeader {
                        source_port,
                        destination_port,
                        length: (UdpHeader::LEN + payload.len()) as u16,
                        checksum: 0,
                    };
                    let checksum = expected_udp_ipv6_checksum(
                        ipv6.source,
                        ipv6.destination,
                        &expected,
                        &payload
                    );
                    expected.checksum = checksum;
                    expected
                }
            );

            // case where the 16 bit word results in a checksum of
            // 0, but gets converted to 0xffff as 0 is reserved.
            {
                let base = UdpHeader {
                    source_port: 0,
                    destination_port,
                    length: (UdpHeader::LEN + payload.len()) as u16,
                    checksum: 0,
                };
                // use the source port to force 0 as a result value
                // for that first calculate the checksum with the source
                // set to 0
                let sourceless_checksum = !(expected_udp_ipv6_checksum(
                    ipv6.source,
                    ipv6.destination,
                    &base,
                    &payload
                ).to_le());

                assert_eq!(
                    UdpHeader::with_ipv6_checksum(
                        // we now need to add a value that results in the value
                        // 0xffff (which will become 0 via the ones complement rule).
                        0xffff - sourceless_checksum,
                        destination_port,
                        &ipv6,
                        &payload
                    ).unwrap(),
                    UdpHeader{
                        source_port: 0xffff - sourceless_checksum,
                        destination_port,
                        length: base.length,
                        checksum: 0xffff
                    }
                );
            }

            // length error case
            {
                // SAFETY: In case the error is not triggered
                //         a segmentation fault will be triggered.
                let too_big_slice = unsafe {
                    //NOTE: The pointer must be initialized with a non null value
                    //      otherwise a key constraint of slices is not fulfilled
                    //      which can lead to crashes in release mode.
                    use core::ptr::NonNull;
                    core::slice::from_raw_parts(
                        NonNull::<u8>::dangling().as_ptr(),
                        bad_len
                    )
                };
                assert_eq!(
                    UdpHeader::with_ipv6_checksum(
                        source_port,
                        destination_port,
                        &ipv6,
                        &too_big_slice
                    ).unwrap_err(),
                    ValueTooBigError{
                        actual: bad_len,
                        max_allowed: usize::from(u16::MAX) - UdpHeader::LEN,
                        value_type: err::ValueType::UdpPayloadLengthIpv6,
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        #[cfg(not(any(target_pointer_width = "16", target_pointer_width = "32")))]
        fn calc_checksum_ipv6_raw(
            source_port in any::<u16>(),
            destination_port in any::<u16>(),
            dummy_checksum in any::<u16>(),
            ipv6 in ipv6_any(),
            payload in proptest::collection::vec(any::<u8>(), 0..20),
            bad_len in ((core::u32::MAX as usize) - UdpHeader::LEN + 1)..=(isize::MAX as usize),
        ) {
            // normal case
            {
                let header = UdpHeader {
                    source_port,
                    destination_port,
                    length: (UdpHeader::LEN + payload.len()) as u16,
                    checksum: dummy_checksum,
                };

                assert_eq!(
                    header.calc_checksum_ipv6_raw(
                        ipv6.source,
                        ipv6.destination,
                        &payload
                    ).unwrap(),
                    expected_udp_ipv6_checksum(
                        ipv6.source,
                        ipv6.destination,
                        &header,
                        &payload
                    )
                );
            }

            // case where the 16 bit word results in a checksum of
            // 0, but gets converted to 0xffff as 0 is reserved.
            {
                let base = UdpHeader {
                    source_port: 0,
                    destination_port,
                    length: (UdpHeader::LEN + payload.len()) as u16,
                    checksum: dummy_checksum,
                };
                // use the source port to force 0 as a result value
                // for that first calculate the checksum with the source
                // set to 0
                let sourceless_checksum = !(expected_udp_ipv6_checksum(
                    ipv6.source,
                    ipv6.destination,
                    &base,
                    &payload
                ).to_le());

                // we now need to add a value that results in the value
                // 0xffff (which will become 0 via the ones complement rule).
                let header = {
                    let mut header = base.clone();
                    header.source_port = 0xffff - sourceless_checksum;
                    header
                };

                assert_eq!(
                    0xffff,
                    header.calc_checksum_ipv6_raw(
                        ipv6.source,
                        ipv6.destination,
                        &payload
                    ).unwrap()
                );
            }

            // length error case
            {
                let header = UdpHeader {
                    source_port,
                    destination_port,
                    // udp header length itself is ok, but the payload not
                    length: (UdpHeader::LEN + payload.len()) as u16,
                    checksum: dummy_checksum,
                };
                // SAFETY: In case the error is not triggered
                //         a segmentation fault will be triggered.
                let too_big_slice = unsafe {
                    //NOTE: The pointer must be initialized with a non null value
                    //      otherwise a key constraint of slices is not fulfilled
                    //      which can lead to crashes in release mode.
                    use core::ptr::NonNull;
                    core::slice::from_raw_parts(
                        NonNull::<u8>::dangling().as_ptr(),
                        bad_len
                    )
                };
                assert_eq!(
                    header.calc_checksum_ipv6_raw(
                        ipv6.source,
                        ipv6.destination,
                        too_big_slice
                    ).unwrap_err(),
                    ValueTooBigError{
                        actual: bad_len,
                        max_allowed: (core::u32::MAX as usize) - UdpHeader::LEN,
                        value_type: ValueType::UdpPayloadLengthIpv6,
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn from_slice(
            input in udp_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20)
        ) {
            // serialize
            let mut buffer: Vec<u8> = Vec::with_capacity(8 + dummy_data.len());
            input.write(&mut buffer).unwrap();
            buffer.extend(&dummy_data[..]);

            // calls with a valid result
            {
                let (result, rest) = UdpHeader::from_slice(&buffer[..]).unwrap();
                assert_eq!(result, input);
                assert_eq!(rest, &buffer[8..]);
            }
            #[allow(deprecated)]
            {
                let (result, rest) = UdpHeader::read_from_slice(&buffer[..]).unwrap();
                assert_eq!(result, input);
                assert_eq!(rest, &buffer[8..]);
            }

            // call with not enough data in the slice
            for len in 0..8 {
                assert_eq!(
                    UdpHeader::from_slice(&buffer[0..len]).unwrap_err(),
                    err::LenError{
                        required_len: UdpHeader::LEN,
                        len: len,
                        len_source: LenSource::Slice,
                        layer: err::Layer::UdpHeader,
                        layer_start_offset: 0,
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn from_bytes(input in udp_any()) {
            assert_eq!(
                input,
                UdpHeader::from_bytes(
                    input.to_bytes()
                )
            );
        }
    }

    proptest! {
        #[test]
        fn read(
            input in udp_any(),
            dummy_data in proptest::collection::vec(any::<u8>(), 0..20)
        ) {
            // serialize
            let mut buffer: Vec<u8> = Vec::with_capacity(input.header_len() + dummy_data.len());
            input.write(&mut buffer).unwrap();
            buffer.extend(&dummy_data[..]);

            // normal
            {
                let mut cursor = Cursor::new(&buffer);
                let result = UdpHeader::read(&mut cursor).unwrap();
                assert_eq!(result, input);
                assert_eq!(8, cursor.position());
            }

            // unexpexted eof
            for len in 0..8 {
                let mut cursor = Cursor::new(&buffer[0..len]);
                assert!(
                    UdpHeader::read(&mut cursor)
                    .is_err()
                );
            }
        }
    }

    proptest! {
        #[test]
        fn write(input in udp_any()) {
            // normal write
            {
                let mut result = Vec::with_capacity(input.header_len());
                input.write(&mut result).unwrap();
                assert_eq!(
                    &result[..],
                    input.to_bytes()
                );
            }

            // unexpected eof
            for len in 0..8 {
                let mut buffer = [0u8; 8];
                let mut cursor = Cursor::new(&mut buffer[..len]);
                assert!(
                    input.write(&mut cursor)
                        .is_err()
                );
            }
        }
    }

    proptest! {
        #[test]
        fn to_bytes(input in udp_any()) {
            let s_be = input.source_port.to_be_bytes();
            let d_be = input.destination_port.to_be_bytes();
            let l_be = input.length.to_be_bytes();
            let c_be = input.checksum.to_be_bytes();

            assert_eq!(
                input.to_bytes(),
                [
                    s_be[0],
                    s_be[1],
                    d_be[0],
                    d_be[1],
                    l_be[0],
                    l_be[1],
                    c_be[0],
                    c_be[1],
                ]
            );
        }
    }

    #[test]
    fn default() {
        let actual: UdpHeader = Default::default();
        assert_eq!(actual.source_port, 0);
        assert_eq!(actual.destination_port, 0);
        assert_eq!(actual.length, 0);
        assert_eq!(actual.checksum, 0);
    }

    proptest! {
        #[test]
        fn clone_eq(input in udp_any()) {
            assert_eq!(input, input.clone());
            {
                let mut other = input.clone();
                other.source_port = !input.source_port;
                assert!(input != other);
            }
        }
    }

    proptest! {
        #[test]
        fn dbg(input in udp_any()) {
            assert_eq!(
                &format!(
                    "UdpHeader {{ source_port: {}, destination_port: {}, length: {}, checksum: {} }}",
                    input.source_port,
                    input.destination_port,
                    input.length,
                    input.checksum,
                ),
                &format!("{:?}", input)
            );
        }
    }
}
