use crate::*;

/// A slice containing an ICMPv6 network package.
///
/// Struct allows the selective read of fields in the ICMPv6
/// packet.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Icmpv6Slice<'a> {
    pub(crate) slice: &'a [u8],
}

impl<'a> Icmpv6Slice<'a> {
    /// Creates a slice containing an ICMPv6 packet.
    ///
    /// # Errors
    ///
    /// The function will return an `Err` [`err::LenError`]
    /// if the given slice is too small (smaller then [`Icmpv6Header::MIN_LEN`]) or
    /// too large (bigger then [`icmpv6::MAX_ICMPV6_BYTE_LEN`]).
    #[inline]
    pub fn from_slice(slice: &'a [u8]) -> Result<Icmpv6Slice<'a>, err::LenError> {
        //check length
        if slice.len() < Icmpv6Header::MIN_LEN {
            return Err(err::LenError {
                required_len: Icmpv6Header::MIN_LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::Icmpv6,
                layer_start_offset: 0,
            });
        }
        if slice.len() > icmpv6::MAX_ICMPV6_BYTE_LEN {
            return Err(err::LenError {
                required_len: icmpv6::MAX_ICMPV6_BYTE_LEN,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: err::Layer::Icmpv6,
                layer_start_offset: 0,
            });
        }

        //done
        Ok(Icmpv6Slice { slice })
    }

    /// Decode the header fields and copy the results to a [`Icmpv6Header`] struct.
    #[inline]
    pub fn header(&self) -> Icmpv6Header {
        Icmpv6Header {
            icmp_type: self.icmp_type(),
            checksum: self.checksum(),
        }
    }

    /// Number of bytes/octets that will be converted into a
    /// [`Icmpv6Header`] when [`Icmpv6Slice::header`] gets called.
    #[inline]
    pub fn header_len(&self) -> usize {
        8
    }

    /// Decode the header values (excluding the checksum) into an [`Icmpv6Type`] enum.
    pub fn icmp_type(&self) -> Icmpv6Type {
        use crate::{icmpv6::*, Icmpv6Type::*};

        match self.type_u8() {
            TYPE_DST_UNREACH => {
                if let Some(code) = DestUnreachableCode::from_u8(self.code_u8()) {
                    return DestinationUnreachable(code);
                }
            }
            TYPE_PACKET_TOO_BIG if 0 == self.code_u8() => {
                return PacketTooBig {
                    mtu: u32::from_be_bytes(self.bytes5to8()),
                };
            }
            TYPE_TIME_EXCEEDED => {
                if let Some(code) = TimeExceededCode::from_u8(self.code_u8()) {
                    return TimeExceeded(code);
                }
            }
            TYPE_PARAMETER_PROBLEM => {
                if let Some(code) = ParameterProblemCode::from_u8(self.code_u8()) {
                    return ParameterProblem(ParameterProblemHeader {
                        code,
                        pointer: u32::from_be_bytes(self.bytes5to8()),
                    });
                }
            }
            TYPE_ECHO_REQUEST if 0 == self.code_u8() => {
                return EchoRequest(IcmpEchoHeader::from_bytes(self.bytes5to8()));
            }
            TYPE_ECHO_REPLY if 0 == self.code_u8() => {
                return EchoReply(IcmpEchoHeader::from_bytes(self.bytes5to8()));
            }
            TYPE_ROUTER_SOLICITATION if 0 == self.code_u8() => {
                return RouterSolicitation;
            }
            TYPE_ROUTER_ADVERTISEMENT if 0 == self.code_u8() => {
                return RouterAdvertisement(RouterAdvertisementHeader::from_bytes(
                    self.bytes5to8(),
                ));
            }
            TYPE_NEIGHBOR_SOLICITATION if 0 == self.code_u8() => {
                return NeighborSolicitation;
            }
            TYPE_NEIGHBOR_ADVERTISEMENT if 0 == self.code_u8() => {
                return NeighborAdvertisement(NeighborAdvertisementHeader::from_bytes(
                    self.bytes5to8(),
                ));
            }
            TYPE_REDIRECT_MESSAGE if 0 == self.code_u8() => {
                return Redirect;
            }
            _ => {}
        }
        Unknown {
            type_u8: self.type_u8(),
            code_u8: self.code_u8(),
            bytes5to8: self.bytes5to8(),
        }
    }

    /// Returns "type" value in the ICMPv6 header.
    #[inline]
    pub fn type_u8(&self) -> u8 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Icmpv6Header::MIN_LEN (8).
        unsafe { *self.slice.get_unchecked(0) }
    }

    /// Returns "code" value in the ICMPv6 header.
    #[inline]
    pub fn code_u8(&self) -> u8 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Icmpv6Header::MIN_LEN (8).
        unsafe { *self.slice.get_unchecked(1) }
    }

    /// Returns "checksum" value in the ICMPv6 header.
    #[inline]
    pub fn checksum(&self) -> u16 {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Icmpv6Header::MIN_LEN  (8).
        unsafe { get_unchecked_be_u16(self.slice.as_ptr().add(2)) }
    }

    /// Returns if the checksum in the slice is correct.
    pub fn is_checksum_valid(&self, source_ip: [u8; 16], destination_ip: [u8; 16]) -> bool {
        // NOTE: rfc4443 section 2.3 - Icmp6 *does* use a pseudoheader,
        // unlike Icmp4
        checksum::Sum16BitWords::new()
            .add_16bytes(source_ip)
            .add_16bytes(destination_ip)
            .add_4bytes((self.slice().len() as u32).to_be_bytes())
            .add_2bytes([0, ip_number::IPV6_ICMP.0])
            // NOTE: From RFC 1071
            // To check a checksum, the 1's complement sum is computed over the
            // same set of octets, including the checksum field.  If the result
            // is all 1 bits (-0 in 1's complement arithmetic), the check
            // succeeds.
            .add_slice(self.slice)
            .ones_complement()
            == 0
    }

    /// Returns the bytes from position 4 till and including the 8th position
    /// in the ICMPv6 header.
    ///
    /// These bytes located at th 5th, 6th, 7th and 8th position of the ICMP
    /// packet can depending on the ICMPv6 type and code contain additional data.
    #[inline]
    pub fn bytes5to8(&self) -> [u8; 4] {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Icmpv6Header::MIN_LEN  (8).
        unsafe {
            [
                *self.slice.get_unchecked(4),
                *self.slice.get_unchecked(5),
                *self.slice.get_unchecked(6),
                *self.slice.get_unchecked(7),
            ]
        }
    }

    /// Returns the slice containing the ICMPv6 packet.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Returns a slice to the bytes not covered by `.header()`.
    #[inline]
    pub fn payload(&self) -> &'a [u8] {
        // SAFETY:
        // Safe as the contructor checks that the slice has
        // at least the length of Icmpv6Header::MIN_LEN(8).
        unsafe { core::slice::from_raw_parts(self.slice.as_ptr().add(8), self.slice.len() - 8) }
    }

    /// Returns the structured payload of the ICMPv6 message if this type is supported.
    #[inline]
    pub fn payload_slice(&self) -> Result<icmpv6::Icmpv6PayloadSlice<'a>, err::LenError> {
        icmpv6::Icmpv6PayloadSlice::from_type_u8(self.type_u8(), self.code_u8(), self.payload())
    }
}

#[cfg(test)]
mod test {
    use crate::{icmpv6::*, test_gens::*, Icmpv6Type::*, *};
    use alloc::{format, vec::Vec};
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn from_slice(slice in proptest::collection::vec(any::<u8>(), 8..1024)) {
            // ok case
            assert_eq!(Icmpv6Slice::from_slice(&slice[..]).unwrap().slice(), &slice[..]);

            // too small size error case
            for len in 0..8 {
                assert_eq!(
                    Icmpv6Slice::from_slice(&slice[..len]).unwrap_err(),
                    err::LenError{
                        required_len: Icmpv6Header::MIN_LEN,
                        len: len,
                        len_source: LenSource::Slice,
                        layer: err::Layer::Icmpv6,
                        layer_start_offset: 0,
                    }
                );
            }
        }
    }

    proptest! {
        /// This error can only occur on systems with a pointer size
        /// bigger then 64 bits.
        #[cfg(not(any(target_pointer_width = "16", target_pointer_width = "32")))]
        #[test]
        fn from_slice_too_big_error(
            bad_len in ((core::u32::MAX as usize) + 1)..=(core::isize::MAX as usize),
        ) {
            // too large packet error case
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
                    Icmpv6Slice::from_slice(too_big_slice).unwrap_err(),
                    err::LenError{
                        required_len: u32::MAX as usize,
                        len: bad_len,
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
        fn header(
            icmp_type in icmpv6_type_any(),
            checksum in any::<u16>()
        ) {
            let expected = Icmpv6Header {
                icmp_type,
                checksum
            };
            assert_eq!(
                Icmpv6Slice::from_slice(&expected.to_bytes()).unwrap().header(),
                expected
            );
        }
    }

    proptest! {
        #[test]
        fn icmp_type(
            checksum in any::<[u8;2]>(),
            bytes5to8 in any::<[u8;4]>()
        ) {
            use Icmpv6Type::*;

            let gen_bytes = |type_u8: u8, code_u8: u8| -> [u8;8] {
                [
                    type_u8, code_u8, checksum[0], checksum[1],
                    bytes5to8[0], bytes5to8[1], bytes5to8[2], bytes5to8[3]
                ]
            };

            let assert_unknown = |type_u8: u8, code_u8: u8| {
                assert_eq!(
                    Icmpv6Slice::from_slice(&gen_bytes(type_u8, code_u8)).unwrap().icmp_type(),
                    Unknown{
                        type_u8,
                        code_u8,
                        bytes5to8,
                    }
                );
            };

            // destination unreachable
            {
                // known codes
                for (code, code_u8) in dest_unreachable_code_test_consts::VALID_VALUES {
                    assert_eq!(
                        Icmpv6Slice::from_slice(&gen_bytes(TYPE_DST_UNREACH, code_u8)).unwrap().icmp_type(),
                        DestinationUnreachable(code)
                    );
                }

                // unknown codes
                for code_u8 in 7..=u8::MAX {
                    assert_unknown(TYPE_DST_UNREACH, code_u8);
                }
            }

            // packet too big
            {
                // known code
                assert_eq!(
                    Icmpv6Slice::from_slice(&gen_bytes(TYPE_PACKET_TOO_BIG, 0)).unwrap().icmp_type(),
                    PacketTooBig {
                        mtu: u32::from_be_bytes(bytes5to8)
                    }
                );

                // unknown code
                for code_u8 in 1..=u8::MAX {
                    assert_unknown(TYPE_PACKET_TOO_BIG, code_u8);
                }
            }

            // time exceeded
            {
                // known codes
                for (code, code_u8) in time_exceeded_code_test_consts::VALID_VALUES {
                    assert_eq!(
                        Icmpv6Slice::from_slice(&gen_bytes(TYPE_TIME_EXCEEDED, code_u8)).unwrap().icmp_type(),
                        TimeExceeded(code)
                    );
                }

                // unknown codes
                for code_u8 in 2..=u8::MAX {
                    assert_unknown(TYPE_TIME_EXCEEDED, code_u8);
                }
            }

            // parameter problem
            {
                // known codes
                for (code, code_u8) in parameter_problem_code_test_consts::VALID_VALUES {
                    assert_eq!(
                        Icmpv6Slice::from_slice(&gen_bytes(TYPE_PARAMETER_PROBLEM, code_u8)).unwrap().icmp_type(),
                        ParameterProblem(ParameterProblemHeader{
                            code,
                            pointer: u32::from_be_bytes(bytes5to8),
                        })
                    );
                }

                // unknown codes
                for code_u8 in 11..=u8::MAX {
                    assert_unknown(TYPE_PARAMETER_PROBLEM, code_u8);
                }
            }

            // echo request
            {
                // known code
                assert_eq!(
                    Icmpv6Slice::from_slice(&gen_bytes(TYPE_ECHO_REQUEST, 0)).unwrap().icmp_type(),
                    EchoRequest(IcmpEchoHeader::from_bytes(bytes5to8))
                );

                // unknown codes
                for code_u8 in 1..=u8::MAX {
                    assert_unknown(TYPE_ECHO_REPLY, code_u8);
                }
            }

            // echo reply
            {
                // known code
                assert_eq!(
                    Icmpv6Slice::from_slice(&gen_bytes(TYPE_ECHO_REPLY, 0)).unwrap().icmp_type(),
                    EchoReply(IcmpEchoHeader::from_bytes(bytes5to8))
                );

                // unknown codes
                for code_u8 in 1..=u8::MAX {
                    assert_unknown(TYPE_ECHO_REPLY, code_u8);
                }
            }

            // neighbor solicitation
            {
                // known code
                assert_eq!(
                    Icmpv6Slice::from_slice(&gen_bytes(TYPE_NEIGHBOR_SOLICITATION, 0)).unwrap().icmp_type(),
                    NeighborSolicitation
                );

                // unknown codes
                for code_u8 in 1..=u8::MAX {
                    assert_unknown(TYPE_NEIGHBOR_SOLICITATION, code_u8);
                }
            }

            // neighbor advertisement
            {
                // known code
                assert_eq!(
                    Icmpv6Slice::from_slice(&gen_bytes(TYPE_NEIGHBOR_ADVERTISEMENT, 0)).unwrap().icmp_type(),
                    NeighborAdvertisement(NeighborAdvertisementHeader::from_bytes(bytes5to8))
                );

                // unknown codes
                for code_u8 in 1..=u8::MAX {
                    assert_unknown(TYPE_NEIGHBOR_ADVERTISEMENT, code_u8);
                }
            }
        }
    }

    proptest! {
        #[test]
        fn header_len(
            code_u8 in any::<u8>(),
            bytes5to8 in any::<[u8;4]>(),
        ) {
            let len_8_types = [
                DestinationUnreachable(DestUnreachableCode::Prohibited),
                PacketTooBig{ mtu: u32::from_be_bytes(bytes5to8), },
                TimeExceeded(TimeExceededCode::HopLimitExceeded),
                ParameterProblem(
                    ParameterProblemHeader{
                        code: ParameterProblemCode::OptionTooBig,
                        pointer: u32::from_be_bytes(bytes5to8),
                    }
                ),
                EchoRequest(IcmpEchoHeader::from_bytes(bytes5to8)),
                EchoReply(IcmpEchoHeader::from_bytes(bytes5to8)),
            ];

            for t in len_8_types {
                assert_eq!(
                    t.header_len(),
                    Icmpv6Slice::from_slice(
                        &Icmpv6Header::new(t).to_bytes()
                    ).unwrap().header_len()
                );
            }

            for t in 0..=u8::MAX {
                let header = Icmpv6Header::new(
                    Unknown{
                        type_u8: t,
                        code_u8,
                        bytes5to8,
                    }
                );
                assert_eq!(
                    8,
                    Icmpv6Slice::from_slice(
                        &header.to_bytes()
                    ).unwrap().header_len()
                );
            }
        }
    }

    proptest! {
        #[test]
        fn type_u8(slice in proptest::collection::vec(any::<u8>(), 8..16)) {
            assert_eq!(
                Icmpv6Slice::from_slice(&slice[..]).unwrap().type_u8(),
                slice[0]
            );
        }
    }

    proptest! {
        #[test]
        fn code_u8(slice in proptest::collection::vec(any::<u8>(), 8..16)) {
            assert_eq!(
                Icmpv6Slice::from_slice(&slice[..]).unwrap().code_u8(),
                slice[1]
            );
        }
    }

    proptest! {
        #[test]
        fn checksum(slice in proptest::collection::vec(any::<u8>(), 8..16)) {
            assert_eq!(
                Icmpv6Slice::from_slice(&slice[..]).unwrap().checksum(),
                u16::from_be_bytes([slice[2], slice[3]])
            );
        }
    }

    proptest! {
        #[test]
        fn is_checksum_valid(
            ip_header in ipv6_any(),
            icmp_type in icmpv6_type_any(),
            payload in proptest::collection::vec(any::<u8>(), 0..1024),
            flip_byte in 0usize..1032,
        ) {
            // generate slice with a correct checksum
            let header = Icmpv6Header::with_checksum(icmp_type, ip_header.source, ip_header.destination, &payload).unwrap();
            let bytes = {
                let mut bytes = Vec::with_capacity(header.header_len() + payload.len());
                header.write(&mut bytes).unwrap();
                bytes.extend_from_slice(&payload);
                bytes
            };

            // check that the checksum gets reported as ok
            assert!(
                Icmpv6Slice::from_slice(&bytes).unwrap().is_checksum_valid(ip_header.source, ip_header.destination)
            );

            // corrupt icmp packet
            {
                let mut corrupted_bytes = bytes.clone();
                let i = flip_byte % corrupted_bytes.len();
                corrupted_bytes[i] = !corrupted_bytes[i];

                assert_eq!(
                    false,
                    Icmpv6Slice::from_slice(&corrupted_bytes).unwrap().is_checksum_valid(ip_header.source, ip_header.destination)
                );
            }

            // corrupt ip source
            {
                let mut corrupted_source = ip_header.source;
                let i = flip_byte % corrupted_source.len();
                corrupted_source[i] = !corrupted_source[i];

                assert_eq!(
                    false,
                    Icmpv6Slice::from_slice(&bytes).unwrap().is_checksum_valid(corrupted_source, ip_header.destination)
                );
            }

            // corrupt ip destination
            {
                let mut corrupted_dest = ip_header.destination;
                let i = flip_byte % corrupted_dest.len();
                corrupted_dest[i] = !corrupted_dest[i];

                assert_eq!(
                    false,
                    Icmpv6Slice::from_slice(&bytes).unwrap().is_checksum_valid(ip_header.source, corrupted_dest)
                );
            }

            // corrupt length
            {
                let mut larger_bytes = bytes.clone();
                larger_bytes.push(0);
                larger_bytes.push(0);

                assert_eq!(
                    false,
                    Icmpv6Slice::from_slice(&larger_bytes).unwrap().is_checksum_valid(ip_header.source, ip_header.destination)
                );
            }
        }
    }

    proptest! {
        #[test]
        fn bytes5to8(slice in proptest::collection::vec(any::<u8>(), 8..16)) {
            assert_eq!(
                Icmpv6Slice::from_slice(&slice[..]).unwrap().bytes5to8(),
                [slice[4], slice[5], slice[6], slice[7]]
            );
        }
    }

    proptest! {
        #[test]
        fn slice(slice in proptest::collection::vec(any::<u8>(), 8..16)) {
            assert_eq!(
                Icmpv6Slice::from_slice(&slice[..]).unwrap().slice(),
                &slice[..]
            );
        }
    }

    proptest! {
        #[test]
        fn payload(
            type_u8 in any::<u8>(),
            code_u8 in any::<u8>(),
            bytes5to8 in any::<[u8;4]>(),
            payload in proptest::collection::vec(any::<u8>(), 8..16)
        ) {
            let len_8_types = [
                Unknown{
                    type_u8,
                    code_u8,
                    bytes5to8,
                },
                DestinationUnreachable(DestUnreachableCode::Prohibited),
                PacketTooBig{ mtu: u32::from_be_bytes(bytes5to8), },
                TimeExceeded(TimeExceededCode::HopLimitExceeded),
                ParameterProblem(
                    ParameterProblemHeader{
                        code: ParameterProblemCode::ExtensionHeaderChainTooLong,
                        pointer: u32::from_be_bytes(bytes5to8),
                    }
                ),
                EchoRequest(IcmpEchoHeader::from_bytes(bytes5to8)),
                EchoReply(IcmpEchoHeader::from_bytes(bytes5to8)),
            ];

            for t in len_8_types {
                let mut bytes = Vec::with_capacity(t.header_len() + payload.len());
                Icmpv6Header::new(t.clone()).write(&mut bytes).unwrap();
                bytes.extend_from_slice(&payload);

                assert_eq!(
                    Icmpv6Slice::from_slice(&bytes[..]).unwrap().payload(),
                    &payload[..]
                );
            }
        }
    }

    #[test]
    fn payload_slice() {
        use crate::icmpv6::*;

        {
            let packet = [
                TYPE_ROUTER_SOLICITATION,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                1,
                1,
                1,
                2,
                3,
                4,
                5,
                6,
            ];
            let slice = Icmpv6Slice::from_slice(&packet).unwrap();
            assert_eq!(slice.icmp_type(), RouterSolicitation);
            assert_eq!(
                slice.payload_slice().unwrap(),
                Icmpv6PayloadSlice::RouterSolicitation(
                    RouterSolicitationPayloadSlice::from_slice(&packet[8..]).unwrap()
                )
            );
        }

        {
            let packet = [
                TYPE_ROUTER_ADVERTISEMENT,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                2,
                5,
                1,
                0,
                0,
                0,
                0,
                5,
                220,
            ];
            let slice = Icmpv6Slice::from_slice(&packet).unwrap();
            assert_eq!(
                slice.icmp_type(),
                RouterAdvertisement(RouterAdvertisementHeader {
                    cur_hop_limit: 0,
                    managed_address_config: false,
                    other_config: false,
                    router_lifetime: 0,
                })
            );
            assert_eq!(
                slice.payload_slice().unwrap(),
                Icmpv6PayloadSlice::RouterAdvertisement(
                    RouterAdvertisementPayloadSlice::from_slice(&packet[8..]).unwrap()
                )
            );
        }

        {
            let mut packet = [0u8; 24];
            packet[0] = TYPE_NEIGHBOR_SOLICITATION;
            packet[8..24].copy_from_slice(&[1; 16]);
            let slice = Icmpv6Slice::from_slice(&packet).unwrap();
            assert_eq!(
                slice.payload_slice().unwrap(),
                Icmpv6PayloadSlice::NeighborSolicitation(
                    NeighborSolicitationPayloadSlice::from_slice(&packet[8..]).unwrap()
                )
            );
        }

        {
            let mut packet = [0u8; 24];
            packet[0] = TYPE_NEIGHBOR_ADVERTISEMENT;
            packet[8..24].copy_from_slice(&[2; 16]);
            let slice = Icmpv6Slice::from_slice(&packet).unwrap();
            assert_eq!(
                slice.payload_slice().unwrap(),
                Icmpv6PayloadSlice::NeighborAdvertisement(
                    NeighborAdvertisementPayloadSlice::from_slice(&packet[8..]).unwrap()
                )
            );
        }

        {
            let mut packet = [0u8; 40];
            packet[0] = TYPE_REDIRECT_MESSAGE;
            packet[8..24].copy_from_slice(&[3; 16]);
            packet[24..40].copy_from_slice(&[4; 16]);
            let slice = Icmpv6Slice::from_slice(&packet).unwrap();
            assert_eq!(slice.icmp_type(), Redirect);
            assert_eq!(
                slice.payload_slice().unwrap(),
                Icmpv6PayloadSlice::Redirect(
                    RedirectPayloadSlice::from_slice(&packet[8..]).unwrap()
                )
            );
        }

        {
            let packet = [TYPE_ECHO_REQUEST, 0, 0, 0, 0, 0, 0, 0, 9, 9];
            let slice = Icmpv6Slice::from_slice(&packet).unwrap();
            assert_eq!(
                slice.payload_slice().unwrap(),
                Icmpv6PayloadSlice::EchoRequest(
                    EchoRequestPayloadSlice::from_slice(&packet[8..]).unwrap()
                )
            );
        }

        {
            let packet = [TYPE_ECHO_REPLY, 0, 0, 0, 0, 0, 0, 0, 7, 7];
            let slice = Icmpv6Slice::from_slice(&packet).unwrap();
            assert_eq!(
                slice.payload_slice().unwrap(),
                Icmpv6PayloadSlice::EchoReply(
                    EchoReplyPayloadSlice::from_slice(&packet[8..]).unwrap()
                )
            );
        }
    }

    #[test]
    fn debug() {
        let data = [0u8; 8];
        assert_eq!(
            format!("{:?}", Icmpv6Slice::from_slice(&data).unwrap()),
            format!("Icmpv6Slice {{ slice: {:?} }}", &data)
        );
    }

    proptest! {
        #[test]
        fn clone_eq(slice in proptest::collection::vec(any::<u8>(), 8..16)) {
            assert_eq!(
                Icmpv6Slice::from_slice(&slice).unwrap().clone(),
                Icmpv6Slice::from_slice(&slice).unwrap()
            );
        }
    }
}
