use super::{ArpHardwareId, ArpOperation};
use crate::{
    err::{Layer, LenError},
    ArpPacket, EtherType, LenSource,
};

/// Slice containing an "Address Resolution Protocol" Packet.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ArpPacketSlice<'a> {
    slice: &'a [u8],
}

impl<'a> ArpPacketSlice<'a> {
    /// Creates an `ArpPacketSlice` from a slice and verifies that the
    /// given slice has enough data to contain an complete ARP packet.
    pub fn from_slice(slice: &'a [u8]) -> Result<ArpPacketSlice<'a>, LenError> {
        if slice.len() < 8 {
            return Err(LenError {
                required_len: 8,
                len: slice.len(),
                len_source: LenSource::Slice,
                layer: Layer::Arp,
                layer_start_offset: 0,
            });
        }

        // validate the rest length based on the hardware & protocol lengths
        let hw_addr_size = unsafe { *slice.as_ptr().add(4) };
        let protocol_addr_size = unsafe { *slice.as_ptr().add(5) };
        let min_len = 8 + (hw_addr_size as usize) * 2 + (protocol_addr_size as usize) * 2;

        if slice.len() < min_len {
            return Err(LenError {
                required_len: min_len,
                len: slice.len(),
                len_source: LenSource::ArpAddrLengths,
                layer: Layer::Arp,
                layer_start_offset: 0,
            });
        }

        Ok(Self {
            slice: unsafe {
                // SAFETY: Safe as slice was verified above to have a
                //         length of at least min_len.
                core::slice::from_raw_parts(slice.as_ptr(), min_len)
            },
        })
    }

    /// Slice containing the ARP packet.
    #[inline]
    pub fn slice(&self) -> &'a [u8] {
        self.slice
    }

    /// Network link protocol type (e.g. `ArpHardwareId::ETHERNET`).
    #[inline]
    pub const fn hw_addr_type(&self) -> ArpHardwareId {
        ArpHardwareId(u16::from_be_bytes(
            // SAFE: As the constructor verified the length
            // of the slice to be at least 8.
            unsafe { [*self.slice.as_ptr(), *self.slice.as_ptr().add(1)] },
        ))
    }

    /// Protocol for which the ARP request is intended (e.g. `EtherType::IPV4`).
    #[inline]
    pub const fn proto_addr_type(&self) -> EtherType {
        EtherType(u16::from_be_bytes(
            // SAFE: As the constructor verified the length
            // of the slice to be at least 8.
            unsafe { [*self.slice.as_ptr().add(2), *self.slice.as_ptr().add(3)] },
        ))
    }

    /// Length (in octets) of a hardware address (e.g. 6 for Ethernet).
    #[inline]
    pub const fn hw_addr_size(&self) -> u8 {
        // SAFE: As the constructor verified the length
        // of the slice to be at least 8.
        unsafe { *self.slice.as_ptr().add(4) }
    }

    /// Length (in octets) of network addresses (e.g. 4 for IPv4 or 16 for IPv6).
    #[inline]
    pub const fn proto_addr_size(&self) -> u8 {
        // SAFE: As the constructor verified the length
        // of the slice to be at least 8.
        unsafe { *self.slice.as_ptr().add(5) }
    }

    /// Specifies the operation that the sender is performing
    #[inline]
    pub const fn operation(&self) -> ArpOperation {
        ArpOperation(u16::from_be_bytes(
            // SAFE: As the constructor verified the length
            // of the slice to be at least 8.
            unsafe { [*self.slice.as_ptr().add(6), *self.slice.as_ptr().add(7)] },
        ))
    }

    /// Sender hardware address (e.g. MAC address).
    #[inline]
    pub const fn sender_hw_addr(&self) -> &[u8] {
        // SAFETY: Safe as the constructor verifies the
        //         the slice to be at least 8 + hw_addr_size*2 + protocol_addr_size*2
        unsafe {
            core::slice::from_raw_parts(self.slice.as_ptr().add(8), self.hw_addr_size() as usize)
        }
    }

    /// Sender protocol address (e.g. IPv4 address).
    #[inline]
    pub const fn sender_protocol_addr(&self) -> &[u8] {
        // SAFETY: Safe as the constructor verifies the
        //         the slice to be at least 8 + hw_addr_size*2 + protocol_addr_size*2
        unsafe {
            core::slice::from_raw_parts(
                self.slice.as_ptr().add(8 + (self.hw_addr_size() as usize)),
                self.proto_addr_size() as usize,
            )
        }
    }

    /// Target hardware address (e.g. MAC address).
    #[inline]
    pub const fn target_hw_addr(&self) -> &[u8] {
        // SAFETY: Safe as the constructor verifies the
        //         the slice to be at least 8 + hw_addr_size*2 + protocol_addr_size*2
        unsafe {
            core::slice::from_raw_parts(
                self.slice
                    .as_ptr()
                    .add(8 + (self.hw_addr_size() as usize) + (self.proto_addr_size() as usize)),
                self.hw_addr_size() as usize,
            )
        }
    }

    /// Buffer containing the target protocol address (e.g. IPv4 address)..
    #[inline]
    pub const fn target_protocol_addr(&self) -> &[u8] {
        // SAFETY: Safe as the constructor verifies the
        //         the slice to be at least 8 + hw_addr_size*2 + protocol_addr_size*2
        unsafe {
            core::slice::from_raw_parts(
                self.slice.as_ptr().add(
                    8 + (self.hw_addr_size() as usize) * 2 + (self.proto_addr_size() as usize),
                ),
                self.proto_addr_size() as usize,
            )
        }
    }

    /// Decode fields and return results in an [`ArpPacket`].
    #[inline]
    pub fn to_packet(&self) -> ArpPacket {
        // SAFETY: Safe as all preconditions of new unchecked
        // are fulfilled by the fact that the on the wire packets already
        // fulfill them.
        unsafe {
            ArpPacket::new_unchecked(
                self.hw_addr_type(),
                self.proto_addr_type(),
                self.operation(),
                self.sender_hw_addr(),
                self.sender_protocol_addr(),
                self.target_hw_addr(),
                self.target_protocol_addr(),
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_gens::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn from_slice_with_payload(
            packet in arp_packet_any()
        ) {
            // build slice data
            let data = packet.to_bytes();

            // happy path
            {
                let actual = ArpPacketSlice::from_slice(&data).unwrap();

                assert_eq!(actual.hw_addr_type(), packet.hw_addr_type);
                assert_eq!(actual.proto_addr_type(), packet.proto_addr_type);
                assert_eq!(actual.hw_addr_size(), packet.hw_addr_size());
                assert_eq!(actual.proto_addr_size(), packet.protocol_addr_size());
                assert_eq!(actual.operation(), packet.operation);

                assert_eq!(actual.sender_hw_addr(), packet.sender_hw_addr());
                assert_eq!(actual.sender_protocol_addr(), packet.sender_protocol_addr());
                assert_eq!(actual.target_hw_addr(), packet.target_hw_addr());
                assert_eq!(actual.target_protocol_addr(), packet.target_protocol_addr());

                assert_eq!(&actual.to_packet(), &packet);
            }

            // length error
            for len in 0..(8 + (packet.hw_addr_size() as usize)*2 + (packet.protocol_addr_size() as usize)*2) {
                let err = ArpPacketSlice::from_slice(&data[..len]).unwrap_err();
                if len < 8 {
                    assert_eq!(err, LenError{
                        required_len: 8,
                        len,
                        len_source: LenSource::Slice,
                        layer: Layer::Arp,
                        layer_start_offset: 0,
                    });
                } else {
                    assert_eq!(err, LenError{
                        required_len: 8 + (packet.hw_addr_size() as usize)*2 + (packet.protocol_addr_size() as usize)*2,
                        len,
                        len_source: LenSource::ArpAddrLengths,
                        layer: Layer::Arp,
                        layer_start_offset: 0,
                    });
                }
            }
        }
    }
}
