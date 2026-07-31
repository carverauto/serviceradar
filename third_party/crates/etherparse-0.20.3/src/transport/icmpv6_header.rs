use crate::{err::ValueTooBigError, *};
use arrayvec::ArrayVec;

/// The statically sized data at the start of an ICMPv6 packet (at least the first 8 bytes of an ICMPv6 packet).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Icmpv6Header {
    /// Type & type specific values & code.
    pub icmp_type: Icmpv6Type,
    /// Checksum in the ICMPv6 header.
    pub checksum: u16,
}

impl Icmpv6Header {
    /// Minimum number of bytes an ICMP header needs to have.
    ///
    /// Note that minimum size can be larger depending on
    /// the type and code.
    pub const MIN_LEN: usize = 8;

    /// Deprecated, use [`Icmpv6Header::MIN_LEN`] instead.
    #[deprecated(since = "0.14.0", note = "Please use Icmpv6Header::MIN_LEN instead")]
    pub const MIN_SERIALIZED_SIZE: usize = Icmpv6Header::MIN_LEN;

    /// Maximum number of bytes/octets an Icmpv6Header takes up
    /// in serialized form.
    ///
    /// Currently this number is determined by the biggest
    /// planned ICMPv6 header type, which is currently the
    /// "Neighbor Discovery Protocol" "Redirect" message.
    pub const MAX_LEN: usize = 8 + 16 + 16;

    /// Deprecated, use [`Icmpv6Header::MAX_LEN`] instead.
    #[deprecated(since = "0.14.0", note = "Please use Icmpv6Header::MAX_LEN instead")]
    pub const MAX_SERIALIZED_SIZE: usize = Icmpv6Header::MAX_LEN;

    /// Setups a new header with the checksum being set to 0.
    #[inline]
    pub fn new(icmp_type: Icmpv6Type) -> Icmpv6Header {
        Icmpv6Header {
            icmp_type,
            checksum: 0, // will be filled in later
        }
    }

    /// Creates a [`Icmpv6Header`] with a checksum calculated based
    /// on the given payload & ip addresses from the IPv6 header.
    pub fn with_checksum(
        icmp_type: Icmpv6Type,
        source_ip: [u8; 16],
        destination_ip: [u8; 16],
        payload: &[u8],
    ) -> Result<Icmpv6Header, ValueTooBigError<usize>> {
        let checksum = icmp_type.calc_checksum(source_ip, destination_ip, payload)?;
        Ok(Icmpv6Header {
            icmp_type,
            checksum,
        })
    }

    /// Reads an icmp6 header from a slice directly and returns a tuple
    /// containing the resulting header & unused part of the slice.
    #[inline]
    pub fn from_slice(slice: &[u8]) -> Result<(Icmpv6Header, &[u8]), err::LenError> {
        let header = Icmpv6Slice::from_slice(slice)?.header();
        let len = header.header_len();
        Ok((header, &slice[len..]))
    }

    /// Read a ICMPv6 header from the given reader
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + Sized>(reader: &mut T) -> Result<Icmpv6Header, std::io::Error> {
        // read the initial 8 bytes
        let mut start = [0u8; 8];
        reader.read_exact(&mut start)?;
        Ok(Icmpv6Slice { slice: &start }.header())
    }

    /// Write the ICMPv6 header to the given writer.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        writer.write_all(&self.to_bytes())
    }

    /// Serialized length of the header in bytes/octets.
    ///
    /// Note that this size is not the size of the entire
    /// ICMPv6 packet but only the header.
    #[inline]
    pub fn header_len(&self) -> usize {
        self.icmp_type.header_len()
    }

    /// If the ICMP type has a fixed size returns the number of
    /// bytes that should be present after the header of this type.
    #[inline]
    pub fn fixed_payload_size(&self) -> Option<usize> {
        self.icmp_type.fixed_payload_size()
    }

    /// Updates the checksum of the header.
    pub fn update_checksum(
        &mut self,
        source_ip: [u8; 16],
        destination_ip: [u8; 16],
        payload: &[u8],
    ) -> Result<(), ValueTooBigError<usize>> {
        self.checksum = self
            .icmp_type
            .calc_checksum(source_ip, destination_ip, payload)?;
        Ok(())
    }

    /// Returns the header on the wire bytes.
    #[inline]
    pub fn to_bytes(&self) -> ArrayVec<u8, { Icmpv6Header::MAX_LEN }> {
        let checksum_be = self.checksum.to_be_bytes();

        let return_trivial =
            |type_u8: u8, code_u8: u8| -> ArrayVec<u8, { Icmpv6Header::MAX_LEN }> {
                #[rustfmt::skip]
            let mut re = ArrayVec::from([
                type_u8, code_u8, checksum_be[0], checksum_be[1],
                0, 0, 0, 0,

                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,

                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
            ]);
                // SAFETY: Safe as u8 has no destruction behavior and as 8 is smaller then 20.
                unsafe {
                    re.set_len(8);
                }
                re
            };

        let return_4u8 = |type_u8: u8,
                          code_u8: u8,
                          bytes5to8: [u8; 4]|
         -> ArrayVec<u8, { Icmpv6Header::MAX_LEN }> {
            #[rustfmt::skip]
            let mut re = ArrayVec::from([
                type_u8, code_u8, checksum_be[0], checksum_be[1],
                bytes5to8[0], bytes5to8[1], bytes5to8[2], bytes5to8[3],

                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,

                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
            ]);
            // SAFETY: Safe as u8 has no destruction behavior and as 8 is smaller then 20.
            unsafe {
                re.set_len(8);
            }
            re
        };

        use crate::{icmpv6::*, Icmpv6Type::*};
        match self.icmp_type {
            Unknown {
                type_u8,
                code_u8,
                bytes5to8,
            } => return_4u8(type_u8, code_u8, bytes5to8),
            DestinationUnreachable(header) => return_trivial(TYPE_DST_UNREACH, header.code_u8()),
            PacketTooBig { mtu } => return_4u8(TYPE_PACKET_TOO_BIG, 0, mtu.to_be_bytes()),
            TimeExceeded(code) => return_trivial(TYPE_TIME_EXCEEDED, code.code_u8()),
            ParameterProblem(header) => return_4u8(
                TYPE_PARAMETER_PROBLEM,
                header.code.code_u8(),
                header.pointer.to_be_bytes(),
            ),
            EchoRequest(echo) => return_4u8(TYPE_ECHO_REQUEST, 0, echo.to_bytes()),
            EchoReply(echo) => return_4u8(TYPE_ECHO_REPLY, 0, echo.to_bytes()),
            RouterSolicitation => return_trivial(TYPE_ROUTER_SOLICITATION, 0),
            RouterAdvertisement(header) => {
                return_4u8(TYPE_ROUTER_ADVERTISEMENT, 0, header.to_bytes())
            }
            NeighborSolicitation => return_trivial(TYPE_NEIGHBOR_SOLICITATION, 0),
            NeighborAdvertisement(header) => {
                return_4u8(TYPE_NEIGHBOR_ADVERTISEMENT, 0, header.to_bytes())
            }
            Redirect => return_trivial(TYPE_REDIRECT_MESSAGE, 0),
        }
    }
}

#[cfg(test)]
mod test {
    use crate::{
        err::{ValueTooBigError, ValueType},
        icmpv6::*,
        test_gens::*,
        *,
    };
    use alloc::{format, vec::Vec};
    use arrayvec::ArrayVec;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn new(icmp_type in icmpv6_type_any()) {
            assert_eq!(
                Icmpv6Header::new(icmp_type.clone()),
                Icmpv6Header {
                    icmp_type,
                    checksum: 0,
                }
            );
        }
    }

    proptest! {
        #[cfg(not(any(target_pointer_width = "16", target_pointer_width = "32")))]
        #[test]
        fn with_checksum(
            ip_header in ipv6_any(),
            icmp_type in icmpv6_type_any(),
            // max length is u32::MAX - header_len (7)
            bad_len in (core::u32::MAX - 7) as usize..=(core::isize::MAX as usize),
            payload in proptest::collection::vec(any::<u8>(), 0..1024)
        ) {

            // error case
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
                    Icmpv6Header::with_checksum(icmp_type.clone(), ip_header.source, ip_header.destination, too_big_slice),
                    Err(ValueTooBigError{
                        actual: bad_len,
                        max_allowed: (core::u32::MAX - 8) as usize,
                        value_type: ValueType::Icmpv6PayloadLength,
                    })
                );
            }

            // non error case
            assert_eq!(
                Icmpv6Header::with_checksum(icmp_type.clone(), ip_header.source, ip_header.destination, &payload).unwrap(),
                Icmpv6Header {
                    icmp_type,
                    checksum: icmp_type.calc_checksum(ip_header.source, ip_header.destination, &payload).unwrap(),
                }
            );
        }
    }

    proptest! {
        #[test]
        fn from_slice(
            icmp_type in icmpv6_type_any(),
            checksum in any::<u16>(),
        ) {
            let bytes = {
                Icmpv6Header {
                    icmp_type: icmp_type.clone(),
                    checksum,
                }.to_bytes()
            };

            // ok case
            {
                let result = Icmpv6Header::from_slice(&bytes).unwrap();
                assert_eq!(
                    Icmpv6Header{
                        icmp_type,
                        checksum,
                    },
                    result.0,
                );
                assert_eq!(&bytes[8..], result.1);
            }


            // size error case
            for length in 0..8 {
                assert_eq!(
                    Icmpv6Header::from_slice(&bytes[..length]).unwrap_err(),
                    err::LenError{
                        required_len: bytes.len(),
                        len: length,
                        len_source: LenSource::Slice,
                        layer: err::Layer::Icmpv6,
                        layer_start_offset: 0
                    }
                );
            }
        }
    }

    proptest! {
        #[test]
        fn read(
            icmp_type in icmpv6_type_any(),
            checksum in any::<u16>(),
        ) {
            let header = Icmpv6Header {
                icmp_type: icmp_type.clone(),
                checksum,
            };
            let bytes = header.to_bytes();

            // ok case
            {
                let mut cursor = std::io::Cursor::new(&bytes);
                let result = Icmpv6Header::read(&mut cursor).unwrap();
                assert_eq!(header, result,);
                assert_eq!(header.header_len() as u64, cursor.position());
            }

            // size error case
            for length in 0..header.header_len() {
                let mut cursor = std::io::Cursor::new(&bytes[..length]);
                assert!(Icmpv6Header::read(&mut cursor).is_err());
            }
        }
    }

    proptest! {
        #[test]
        fn write(
            icmp_type in icmpv6_type_any(),
            checksum in any::<u16>(),
            bad_len in 0..8usize
        ) {
            // normal case
            {
                let mut buffer = Vec::with_capacity(icmp_type.header_len());
                let header = Icmpv6Header {
                    icmp_type,
                    checksum,
                };
                header.write(&mut buffer).unwrap();
                assert_eq!(
                    &header.to_bytes(),
                    &buffer[..]
                );
            }

            // error case
            {
                let mut buffer = [0u8;Icmpv6Header::MAX_LEN];
                let mut writer = std::io::Cursor::new(&mut buffer[..bad_len]);
                Icmpv6Header {
                    icmp_type,
                    checksum,
                }.write(&mut writer).unwrap_err();
            }
        }
    }

    proptest! {
        #[test]
        fn header_len(icmp_type in icmpv6_type_any(), checksum in any::<u16>()) {
            assert_eq!(
                icmp_type.header_len(),
                Icmpv6Header{
                    icmp_type,
                    checksum
                }.header_len()
            );
        }
    }

    proptest! {
        #[test]
        fn fixed_payload_size(icmp_type in icmpv6_type_any(), checksum in any::<u16>()) {
            assert_eq!(
                icmp_type.fixed_payload_size(),
                Icmpv6Header{
                    icmp_type,
                    checksum
                }.fixed_payload_size()
            );
        }
    }

    proptest! {
        #[test]
        #[cfg(not(any(target_pointer_width = "16", target_pointer_width = "32")))]
        fn update_checksum(
            ip_header in ipv6_any(),
            icmp_type in icmpv6_type_any(),
            start_checksum in any::<u16>(),
            // max length is u32::MAX - header_len (7)
            bad_len in (core::u32::MAX - 7) as usize..=(core::isize::MAX as usize),
            payload in proptest::collection::vec(any::<u8>(), 0..1024)
        ) {

            // error case
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
                    Icmpv6Header{
                        icmp_type,
                        checksum: 0
                    }.update_checksum(ip_header.source, ip_header.destination, too_big_slice),
                    Err(ValueTooBigError{
                        actual: bad_len,
                        max_allowed: (u32::MAX - 8) as usize,
                        value_type: ValueType::Icmpv6PayloadLength
                    })
                );
            }

            // normal case
            assert_eq!(
                {
                    let mut header = Icmpv6Header{
                        icmp_type,
                        checksum: start_checksum,
                    };
                    header.update_checksum(ip_header.source, ip_header.destination, &payload).unwrap();
                    header
                },
                Icmpv6Header{
                    icmp_type,
                    checksum: icmp_type.calc_checksum(ip_header.source, ip_header.destination, &payload).unwrap(),
                }
            );
        }
    }

    proptest! {
        #[test]
        fn to_bytes(
            checksum in any::<u16>(),
            rand_u32 in any::<u32>(),
            rand_4bytes in any::<[u8;4]>(),
            rand_bool0 in any::<bool>(),
            rand_bool1 in any::<bool>(),
            rand_bool2 in any::<bool>(),
        ) {
            use Icmpv6Type::*;

            let with_5to8_bytes = |type_u8: u8, code_u8: u8, bytes5to8: [u8;4]| -> ArrayVec<u8, { Icmpv6Header::MAX_LEN }> {
                let mut bytes = ArrayVec::<u8, { Icmpv6Header::MAX_LEN }>::new();
                bytes.push(type_u8);
                bytes.push(code_u8);
                bytes.try_extend_from_slice(&checksum.to_be_bytes()).unwrap();
                bytes.try_extend_from_slice(&bytes5to8).unwrap();
                bytes
            };

            let simple_bytes = |type_u8: u8, code_u8: u8| -> ArrayVec<u8, { Icmpv6Header::MAX_LEN }> {
                with_5to8_bytes(type_u8, code_u8, [0;4])
            };

            // destination unreachable
            for (code, code_u8) in dest_unreachable_code_test_consts::VALID_VALUES {
                assert_eq!(
                    Icmpv6Header{
                        icmp_type: DestinationUnreachable(code),
                        checksum
                    }.to_bytes(),
                    simple_bytes(TYPE_DST_UNREACH, code_u8)
                );
            }

            // packet too big
            assert_eq!(
                Icmpv6Header{
                    icmp_type: PacketTooBig{ mtu: rand_u32 },
                    checksum
                }.to_bytes(),
                with_5to8_bytes(TYPE_PACKET_TOO_BIG, 0, rand_u32.to_be_bytes())
            );

            // time exceeded
            for (code, code_u8) in time_exceeded_code_test_consts::VALID_VALUES {
                assert_eq!(
                    Icmpv6Header{
                        icmp_type: TimeExceeded(code),
                        checksum
                    }.to_bytes(),
                    simple_bytes(TYPE_TIME_EXCEEDED, code_u8)
                );
            }

            // parameter problem
            for (code, code_u8) in parameter_problem_code_test_consts::VALID_VALUES {
                assert_eq!(
                    Icmpv6Header{
                        icmp_type: ParameterProblem(
                            ParameterProblemHeader{
                                code,
                                pointer: rand_u32,
                            }
                        ),
                        checksum
                    }.to_bytes(),
                    with_5to8_bytes(TYPE_PARAMETER_PROBLEM, code_u8, rand_u32.to_be_bytes())
                );
            }

            // echo request
            assert_eq!(
                Icmpv6Header{
                    icmp_type: EchoRequest(IcmpEchoHeader {
                        id: u16::from_be_bytes([rand_4bytes[0], rand_4bytes[1]]),
                        seq: u16::from_be_bytes([rand_4bytes[2], rand_4bytes[3]]),
                    }),
                    checksum
                }.to_bytes(),
                with_5to8_bytes(TYPE_ECHO_REQUEST, 0, rand_4bytes)
            );

            // echo reply
            assert_eq!(
                Icmpv6Header{
                    icmp_type: EchoReply(IcmpEchoHeader {
                        id: u16::from_be_bytes([rand_4bytes[0], rand_4bytes[1]]),
                        seq: u16::from_be_bytes([rand_4bytes[2], rand_4bytes[3]]),
                    }),
                    checksum
                }.to_bytes(),
                with_5to8_bytes(TYPE_ECHO_REPLY, 0, rand_4bytes)
            );

            // neighbor solicitation
            assert_eq!(
                Icmpv6Header{
                    icmp_type: NeighborSolicitation,
                    checksum
                }.to_bytes(),
                with_5to8_bytes(TYPE_NEIGHBOR_SOLICITATION, 0, [0;4])
            );

            // neighbor advertisement
            assert_eq!(
                Icmpv6Header{
                    icmp_type: NeighborAdvertisement(
                        NeighborAdvertisementHeader {
                            router: rand_bool0,
                            solicited: rand_bool1,
                            r#override: rand_bool2,
                        }
                    ),
                    checksum
                }.to_bytes(),
                with_5to8_bytes(TYPE_NEIGHBOR_ADVERTISEMENT, 0, [
                    if rand_bool0 {
                        NeighborAdvertisementHeader::ROUTER_MASK
                    } else {
                        0
                    } | if rand_bool1 {
                        NeighborAdvertisementHeader::SOLICITED_MASK
                    } else {
                        0
                    } | if rand_bool2 {
                        NeighborAdvertisementHeader::OVERRIDE_MASK
                    } else {
                        0
                    }, 0, 0, 0
                ])
            );

            // unknown
            for type_u8 in 0..=u8::MAX {
                for code_u8 in 0..=u8::MAX {
                    assert_eq!(
                        Icmpv6Header{
                            icmp_type: Unknown {
                                type_u8,
                                code_u8,
                                bytes5to8: rand_4bytes,
                            },
                            checksum
                        }.to_bytes(),
                        with_5to8_bytes(type_u8, code_u8, rand_4bytes)
                    );
                }
            }
        }
    }

    #[test]
    fn debug() {
        let t = Icmpv6Type::Unknown {
            type_u8: 0,
            code_u8: 1,
            bytes5to8: [2, 3, 4, 5],
        };
        assert_eq!(
            format!(
                "{:?}",
                Icmpv6Header {
                    icmp_type: t.clone(),
                    checksum: 7
                }
            ),
            format!("Icmpv6Header {{ icmp_type: {:?}, checksum: {:?} }}", t, 7)
        );
    }

    proptest! {
        #[test]
        fn clone_eq(icmp_type in icmpv6_type_any(), checksum in any::<u16>()) {
            let header = Icmpv6Header{ icmp_type, checksum };
            assert_eq!(header, header.clone());
        }
    }
}
