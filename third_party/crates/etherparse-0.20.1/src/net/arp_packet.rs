use arrayvec::ArrayVec;
use err::arp::{ArpHwAddrError, ArpNewError, ArpProtoAddrError};

use crate::*;
use core::mem::MaybeUninit;

/// "Address Resolution Protocol" Packet.
#[derive(Clone)]
pub struct ArpPacket {
    /// Network link protocol type (e.g. `ArpHardwareId::ETHERNET`).
    pub hw_addr_type: ArpHardwareId,

    /// Protocol for which the ARP request is intended (e.g. `EtherType::IPV4`).
    pub proto_addr_type: EtherType,

    /// Length (in octets) of a hardware address (e.g. 6 for Ethernet).
    hw_addr_size: u8,

    /// Length (in octets) of internetwork addresses (e.g. 4 for IPv4 or 16 for IPv6).
    proto_addr_size: u8,

    /// Specifies the operation that the sender is performing
    pub operation: ArpOperation,

    /// Buffer containing the sender hardware address (e.g. MAC address).
    sender_hw_addr_buf: [MaybeUninit<u8>; 0xff],

    /// Buffer containing the sender protocol address (e.g. IPv4 address).
    sender_protocol_addr_buf: [MaybeUninit<u8>; 0xff],

    /// Buffer containing the target hardware address (e.g. MAC address).
    target_hw_addr_buf: [MaybeUninit<u8>; 0xff],

    /// Buffer containing the target protocol address (e.g. IPv4 address)..
    target_protocol_addr_buf: [MaybeUninit<u8>; 0xff],
}

impl ArpPacket {
    /// Maximum length of an ARP packet in bytes/octets.
    ///
    /// This number is calculated by taking the maximum values
    /// that `hw_addr_size`(255/u8::MAX) & `proto_addr_size` (255/u8::MAX)
    /// can take and calculate the maximum packet size from that.
    pub const MAX_LEN: usize = 8 + 2 * 255 + 2 * 255;

    /// Create a new ARP packet with the given values.
    pub const fn new(
        hw_addr_type: ArpHardwareId,
        proto_addr_type: EtherType,
        operation: ArpOperation,
        sender_hw_addr: &[u8],
        sender_protocol_addr: &[u8],
        target_hw_addr: &[u8],
        target_protocol_addr: &[u8],
    ) -> Result<ArpPacket, ArpNewError> {
        if sender_hw_addr.len() != target_hw_addr.len() {
            return Err(ArpNewError::HwAddr(ArpHwAddrError::LenNonMatching(
                sender_hw_addr.len(),
                target_hw_addr.len(),
            )));
        }
        if sender_protocol_addr.len() != target_protocol_addr.len() {
            return Err(ArpNewError::ProtoAddr(ArpProtoAddrError::LenNonMatching(
                sender_protocol_addr.len(),
                target_protocol_addr.len(),
            )));
        }
        if sender_hw_addr.len() > 255 {
            return Err(ArpNewError::HwAddr(ArpHwAddrError::LenTooBig(
                sender_hw_addr.len(),
            )));
        }
        if sender_protocol_addr.len() > 255 {
            return Err(ArpNewError::ProtoAddr(ArpProtoAddrError::LenTooBig(
                sender_protocol_addr.len(),
            )));
        }
        Ok(ArpPacket {
            hw_addr_type,
            proto_addr_type,
            // cast ok as we verified the len to be less equal then 255.
            hw_addr_size: sender_hw_addr.len() as u8,
            // cast ok as we verified the len to be less equal then 255.
            proto_addr_size: sender_protocol_addr.len() as u8,
            operation,
            sender_hw_addr_buf: {
                let mut buf: [MaybeUninit<u8>; 255] = [const { MaybeUninit::uninit() }; 255];
                // SAFETY: Safe as
                // * sender_hw_addr.len() is guaranteed to be <= 255 (checked in if above)
                // * memory areas guaranteed to be non overlapping (buf created in this function).
                unsafe {
                    core::ptr::copy_nonoverlapping(
                        sender_hw_addr.as_ptr(),
                        buf.as_mut_ptr() as *mut u8,
                        sender_hw_addr.len(),
                    );
                }
                buf
            },
            sender_protocol_addr_buf: {
                let mut buf: [MaybeUninit<u8>; 255] = [const { MaybeUninit::uninit() }; 255];
                // SAFETY: Safe as
                // * sender_protocol_addr.len() is guaranteed to be <= 255 (checked in if above)
                // * memory areas guaranteed to be non overlapping (buf created in this function).
                unsafe {
                    core::ptr::copy_nonoverlapping(
                        sender_protocol_addr.as_ptr(),
                        buf.as_mut_ptr() as *mut u8,
                        sender_protocol_addr.len(),
                    );
                }
                buf
            },
            target_hw_addr_buf: {
                let mut buf: [MaybeUninit<u8>; 255] = [const { MaybeUninit::uninit() }; 255];
                // SAFETY: Safe as
                // * target_hw_addr.len() is guaranteed to be <= 255 (checked in if above)
                // * memory areas guaranteed to be non overlapping (buf created in this function).
                unsafe {
                    core::ptr::copy_nonoverlapping(
                        target_hw_addr.as_ptr(),
                        buf.as_mut_ptr() as *mut u8,
                        target_hw_addr.len(),
                    );
                }
                buf
            },
            target_protocol_addr_buf: {
                let mut buf: [MaybeUninit<u8>; 255] = [const { MaybeUninit::uninit() }; 255];
                // SAFETY: Safe as
                // * target_protocol_addr.len() is guaranteed to be <= 255 (checked in if above)
                // * memory areas guaranteed to be non overlapping (buf created in this function).
                unsafe {
                    core::ptr::copy_nonoverlapping(
                        target_protocol_addr.as_ptr(),
                        buf.as_mut_ptr() as *mut u8,
                        target_protocol_addr.len(),
                    );
                }
                buf
            },
        })
    }

    /// Create a new ARP packet with the given values without checking
    /// hardware & protocol address sizes.
    ///
    /// # Safety
    ///
    /// The caller must guarantee that
    ///
    /// * `sender_hw_addr` & `target_hw_addr` have the same length and the length must be smaller or equal than 255.
    /// * `sender_protocol_addr` & `target_protocol_addr` have the same length and the length must be smaller or equal than 255.
    ///
    /// The guarantees the caller must fulfill are equal to the following
    /// preconditions:
    ///
    /// * `sender_hw_addr.len() == target_hw_addr.len()`
    /// * `sender_hw_addr.len() <= 255`
    /// * `target_hw_addr.len() <= 255`
    /// * `sender_protocol_addr.len() == target_protocol_addr.len()`
    /// * `sender_protocol_addr.len() <= 255`
    /// * `target_protocol_addr.len() <= 255`
    pub const unsafe fn new_unchecked(
        hw_addr_type: ArpHardwareId,
        proto_addr_type: EtherType,
        operation: ArpOperation,
        sender_hw_addr: &[u8],
        sender_protocol_addr: &[u8],
        target_hw_addr: &[u8],
        target_protocol_addr: &[u8],
    ) -> ArpPacket {
        debug_assert!(sender_hw_addr.len() == target_hw_addr.len());
        debug_assert!(sender_protocol_addr.len() == target_protocol_addr.len());
        debug_assert!(sender_hw_addr.len() <= 255);
        debug_assert!(sender_protocol_addr.len() <= 255);

        ArpPacket {
            hw_addr_type,
            proto_addr_type,
            // cast ok as we verified the len to be less equal then 255.
            hw_addr_size: sender_hw_addr.len() as u8,
            // cast ok as we verified the len to be less equal then 255.
            proto_addr_size: sender_protocol_addr.len() as u8,
            operation,
            sender_hw_addr_buf: {
                let mut buf: [MaybeUninit<u8>; 255] = [const { MaybeUninit::uninit() }; 255];
                // SAFETY: Safe as
                // * the caller must guarantee that sender_hw_addr.len() is <= 255
                // * memory areas guaranteed to be non overlapping (buf created in this function).
                unsafe {
                    core::ptr::copy_nonoverlapping(
                        sender_hw_addr.as_ptr(),
                        buf.as_mut_ptr() as *mut u8,
                        sender_hw_addr.len(),
                    );
                }
                buf
            },
            sender_protocol_addr_buf: {
                let mut buf: [MaybeUninit<u8>; 255] = [const { MaybeUninit::uninit() }; 255];
                // SAFETY: Safe as
                // * the caller must guarantee that sender_protocol_addr.len() is <= 255
                // * memory areas guaranteed to be non overlapping (buf created in this function).
                unsafe {
                    core::ptr::copy_nonoverlapping(
                        sender_protocol_addr.as_ptr(),
                        buf.as_mut_ptr() as *mut u8,
                        sender_protocol_addr.len(),
                    );
                }
                buf
            },
            target_hw_addr_buf: {
                let mut buf: [MaybeUninit<u8>; 255] = [const { MaybeUninit::uninit() }; 255];
                // SAFETY: Safe as
                // * the caller must guarantee that target_hw_addr.len() is <= 255
                // * memory areas guaranteed to be non overlapping (buf created in this function).
                unsafe {
                    core::ptr::copy_nonoverlapping(
                        target_hw_addr.as_ptr(),
                        buf.as_mut_ptr() as *mut u8,
                        target_hw_addr.len(),
                    );
                }
                buf
            },
            target_protocol_addr_buf: {
                let mut buf: [MaybeUninit<u8>; 255] = [const { MaybeUninit::uninit() }; 255];
                // SAFETY: Safe as
                // * the caller must guarantee that target_protocol_addr.len() is <= 255
                // * memory areas guaranteed to be non overlapping (buf created in this function).
                unsafe {
                    core::ptr::copy_nonoverlapping(
                        target_protocol_addr.as_ptr(),
                        buf.as_mut_ptr() as *mut u8,
                        target_protocol_addr.len(),
                    );
                }
                buf
            },
        }
    }

    /// Reads an ARP packet from a slice.
    pub fn from_slice(slice: &[u8]) -> Result<ArpPacket, err::LenError> {
        ArpPacketSlice::from_slice(slice).map(|v| v.to_packet())
    }

    /// Length (in octets) of a hardware address (e.g. 6 for Ethernet).
    #[inline]
    pub const fn hw_addr_size(&self) -> u8 {
        self.hw_addr_size
    }

    /// Length (in octets) of internetwork addresses (e.g. 4 for IPv4 or 16 for IPv6).
    #[inline]
    pub const fn protocol_addr_size(&self) -> u8 {
        self.proto_addr_size
    }

    /// Sender hardware address (e.g. MAC address).
    #[inline]
    pub const fn sender_hw_addr(&self) -> &[u8] {
        unsafe {
            core::slice::from_raw_parts(
                self.sender_hw_addr_buf.as_ptr() as *const u8,
                self.hw_addr_size as usize,
            )
        }
    }

    /// Sender protocol address (e.g. IPv4 address).
    #[inline]
    pub const fn sender_protocol_addr(&self) -> &[u8] {
        unsafe {
            core::slice::from_raw_parts(
                self.sender_protocol_addr_buf.as_ptr() as *const u8,
                self.proto_addr_size as usize,
            )
        }
    }

    /// Target hardware address (e.g. MAC address).
    #[inline]
    pub const fn target_hw_addr(&self) -> &[u8] {
        unsafe {
            core::slice::from_raw_parts(
                self.target_hw_addr_buf.as_ptr() as *const u8,
                self.hw_addr_size as usize,
            )
        }
    }

    /// Target protocol address (e.g. IPv4 address).
    #[inline]
    pub const fn target_protocol_addr(&self) -> &[u8] {
        unsafe {
            core::slice::from_raw_parts(
                self.target_protocol_addr_buf.as_ptr() as *const u8,
                self.proto_addr_size as usize,
            )
        }
    }

    /// Set the sender & target hardware addresses (e.g. MAC address).
    #[inline]
    pub const fn set_hw_addrs(
        &mut self,
        sender_hw_addr: &[u8],
        target_hw_addr: &[u8],
    ) -> Result<(), ArpHwAddrError> {
        if sender_hw_addr.len() != target_hw_addr.len() {
            return Err(ArpHwAddrError::LenNonMatching(
                sender_hw_addr.len(),
                target_hw_addr.len(),
            ));
        }
        if sender_hw_addr.len() > 255 {
            return Err(ArpHwAddrError::LenTooBig(sender_hw_addr.len()));
        }
        {
            // SAFETY: Safe as
            // * the caller must guarantee that sender_hw_addr.len() is <= 255
            // * memory areas guaranteed to be non overlapping (buf created in this function).
            unsafe {
                core::ptr::copy_nonoverlapping(
                    sender_hw_addr.as_ptr(),
                    self.sender_hw_addr_buf.as_mut_ptr() as *mut u8,
                    sender_hw_addr.len(),
                );
            }
        }
        {
            // SAFETY: Safe as
            // * the caller must guarantee that target_hw_addr.len() is <= 255
            // * memory areas guaranteed to be non overlapping (buf created in this function).
            unsafe {
                core::ptr::copy_nonoverlapping(
                    target_hw_addr.as_ptr(),
                    self.target_hw_addr_buf.as_mut_ptr() as *mut u8,
                    target_hw_addr.len(),
                );
            }
        }
        self.hw_addr_size = sender_hw_addr.len() as u8;
        Ok(())
    }

    /// Set the sender & target protocol addresses (e.g. IPv4 address).
    #[inline]
    pub const fn set_protocol_addrs(
        &mut self,
        sender_protocol_addr: &[u8],
        target_protocol_addr: &[u8],
    ) -> Result<(), ArpProtoAddrError> {
        if sender_protocol_addr.len() != target_protocol_addr.len() {
            return Err(ArpProtoAddrError::LenNonMatching(
                sender_protocol_addr.len(),
                target_protocol_addr.len(),
            ));
        }
        if sender_protocol_addr.len() > 255 {
            return Err(ArpProtoAddrError::LenTooBig(sender_protocol_addr.len()));
        }
        {
            // SAFETY: Safe as
            // * sender_protocol_addr.len() is guaranteed to be <= 255 (checked in if above)
            // * memory areas guaranteed to be non overlapping (buf created in this function).
            unsafe {
                core::ptr::copy_nonoverlapping(
                    sender_protocol_addr.as_ptr(),
                    self.sender_protocol_addr_buf.as_mut_ptr() as *mut u8,
                    sender_protocol_addr.len(),
                );
            }
        }
        {
            // SAFETY: Safe as
            // * target_protocol_addr.len() is guaranteed to be <= 255 (checked in if above)
            // * memory areas guaranteed to be non overlapping (buf created in this function).
            unsafe {
                core::ptr::copy_nonoverlapping(
                    target_protocol_addr.as_ptr(),
                    self.target_protocol_addr_buf.as_mut_ptr() as *mut u8,
                    target_protocol_addr.len(),
                );
            }
        }
        self.proto_addr_size = sender_protocol_addr.len() as u8;
        Ok(())
    }

    /// Serialized length of this ARP packet.
    #[inline]
    pub fn packet_len(&self) -> usize {
        8 + usize::from(self.hw_addr_size) * 2 + usize::from(self.proto_addr_size) * 2
    }

    /// Returns the serialized header.
    #[inline]
    pub fn to_bytes(&self) -> ArrayVec<u8, { ArpPacket::MAX_LEN }> {
        let hw_addr_type = self.hw_addr_type.0.to_be_bytes();
        let proto_addr_type = self.proto_addr_type.0.to_be_bytes();
        let operation = self.operation.0.to_be_bytes();
        let mut result = ArrayVec::<u8, { ArpPacket::MAX_LEN }>::new_const();
        result.extend([
            hw_addr_type[0],
            hw_addr_type[1],
            proto_addr_type[0],
            proto_addr_type[1],
            self.hw_addr_size,
            self.proto_addr_size,
            operation[0],
            operation[1],
        ]);
        result.try_extend_from_slice(self.sender_hw_addr()).unwrap();
        result
            .try_extend_from_slice(self.sender_protocol_addr())
            .unwrap();
        result.try_extend_from_slice(self.target_hw_addr()).unwrap();
        result
            .try_extend_from_slice(self.target_protocol_addr())
            .unwrap();
        result
    }

    /// Writes the header to the given writer.
    #[cfg(feature = "std")]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        writer.write_all(&self.to_bytes())?;
        Ok(())
    }

    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn read<T: std::io::Read + std::io::Seek + Sized>(
        reader: &mut T,
    ) -> Result<ArpPacket, std::io::Error> {
        let mut start = [0u8; 8];
        reader.read_exact(&mut start[..])?;

        let mut result = ArpPacket {
            hw_addr_type: ArpHardwareId(u16::from_be_bytes([start[0], start[1]])),
            proto_addr_type: EtherType(u16::from_be_bytes([start[2], start[3]])),
            hw_addr_size: start[4],
            proto_addr_size: start[5],
            operation: ArpOperation(u16::from_be_bytes([start[6], start[7]])),
            sender_hw_addr_buf: [const { MaybeUninit::uninit() }; 255],
            sender_protocol_addr_buf: [const { MaybeUninit::uninit() }; 255],
            target_hw_addr_buf: [const { MaybeUninit::uninit() }; 255],
            target_protocol_addr_buf: [const { MaybeUninit::uninit() }; 255],
        };

        {
            // SAFETY: Safe as the maximum u8 value is equal to the array size 255.
            let sender_hw_addr_slice = unsafe {
                core::slice::from_raw_parts_mut(
                    result.sender_hw_addr_buf.as_mut_ptr() as *mut u8,
                    result.hw_addr_size as usize,
                )
            };
            reader.read_exact(sender_hw_addr_slice)?;
        }
        {
            // SAFETY: Safe as the maximum u8 value is equal to the array size 255.
            let sender_protocol_addr = unsafe {
                core::slice::from_raw_parts_mut(
                    result.sender_protocol_addr_buf.as_mut_ptr() as *mut u8,
                    result.proto_addr_size as usize,
                )
            };
            reader.read_exact(sender_protocol_addr)?;
        }
        {
            // SAFETY: Safe as the maximum u8 value is equal to the array size 255.
            let target_hw_addr = unsafe {
                core::slice::from_raw_parts_mut(
                    result.target_hw_addr_buf.as_mut_ptr() as *mut u8,
                    result.hw_addr_size as usize,
                )
            };
            reader.read_exact(target_hw_addr)?;
        }
        {
            // SAFETY: Safe as the maximum u8 value is equal to the array size 255.
            let target_protocol_addr = unsafe {
                core::slice::from_raw_parts_mut(
                    result.target_protocol_addr_buf.as_mut_ptr() as *mut u8,
                    result.proto_addr_size as usize,
                )
            };
            reader.read_exact(target_protocol_addr)?;
        }

        Ok(result)
    }

    /// Returns an [`ArpEthIpv4Packet`] if the current packet
    /// is an ethernet & IPv4 ARP packet.
    pub fn try_eth_ipv4(&self) -> Result<ArpEthIpv4Packet, err::arp::ArpEthIpv4FromError> {
        use err::arp::ArpEthIpv4FromError::*;
        if self.hw_addr_type != ArpHardwareId::ETHERNET {
            return Err(NonMatchingHwType(self.hw_addr_type));
        }
        if self.proto_addr_type != EtherType::IPV4 {
            return Err(NonMatchingProtocolType(self.proto_addr_type));
        }
        if self.hw_addr_size != 6 {
            return Err(NonMatchingHwAddrSize(self.hw_addr_size));
        }
        if self.proto_addr_size != 4 {
            return Err(NonMatchingProtoAddrSize(self.proto_addr_size));
        }
        Ok(ArpEthIpv4Packet {
            operation: self.operation,
            sender_mac: unsafe {
                // SAFE as we check above that hw_addr_size is 6
                [
                    self.sender_hw_addr_buf[0].assume_init(),
                    self.sender_hw_addr_buf[1].assume_init(),
                    self.sender_hw_addr_buf[2].assume_init(),
                    self.sender_hw_addr_buf[3].assume_init(),
                    self.sender_hw_addr_buf[4].assume_init(),
                    self.sender_hw_addr_buf[5].assume_init(),
                ]
            },
            sender_ipv4: unsafe {
                // SAFE as we check above that proto_addr_size is 6
                [
                    self.sender_protocol_addr_buf[0].assume_init(),
                    self.sender_protocol_addr_buf[1].assume_init(),
                    self.sender_protocol_addr_buf[2].assume_init(),
                    self.sender_protocol_addr_buf[3].assume_init(),
                ]
            },
            target_mac: unsafe {
                // SAFE as we check above that hw_addr_size is 6
                [
                    self.target_hw_addr_buf[0].assume_init(),
                    self.target_hw_addr_buf[1].assume_init(),
                    self.target_hw_addr_buf[2].assume_init(),
                    self.target_hw_addr_buf[3].assume_init(),
                    self.target_hw_addr_buf[4].assume_init(),
                    self.target_hw_addr_buf[5].assume_init(),
                ]
            },
            target_ipv4: unsafe {
                // SAFE as we check above that proto_addr_size is 6
                [
                    self.target_protocol_addr_buf[0].assume_init(),
                    self.target_protocol_addr_buf[1].assume_init(),
                    self.target_protocol_addr_buf[2].assume_init(),
                    self.target_protocol_addr_buf[3].assume_init(),
                ]
            },
        })
    }
}

impl core::fmt::Debug for ArpPacket {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("ArpPacket")
            .field("hw_addr_type", &self.hw_addr_type)
            .field("proto_addr_type", &self.proto_addr_type)
            .field("hw_addr_size", &self.hw_addr_size)
            .field("proto_addr_size", &self.proto_addr_size)
            .field("operation", &self.operation)
            .field("sender_hw_addr", &self.sender_hw_addr())
            .field("sender_protocol_addr", &self.sender_protocol_addr())
            .field("target_hw_addr", &self.target_hw_addr())
            .field("target_protocol_addr", &self.target_protocol_addr())
            .finish()
    }
}

impl core::cmp::PartialEq for ArpPacket {
    fn eq(&self, other: &Self) -> bool {
        self.hw_addr_type == other.hw_addr_type
            && self.proto_addr_type == other.proto_addr_type
            && self.hw_addr_size == other.hw_addr_size
            && self.proto_addr_size == other.proto_addr_size
            && self.operation == other.operation
            && self.sender_hw_addr() == other.sender_hw_addr()
            && self.sender_protocol_addr() == other.sender_protocol_addr()
            && self.target_hw_addr() == other.target_hw_addr()
            && self.target_protocol_addr() == other.target_protocol_addr()
    }
}

impl core::cmp::Eq for ArpPacket {}

impl core::hash::Hash for ArpPacket {
    fn hash<H: core::hash::Hasher>(&self, state: &mut H) {
        self.hw_addr_type.hash(state);
        self.proto_addr_type.hash(state);
        self.hw_addr_size.hash(state);
        self.proto_addr_size.hash(state);
        self.operation.hash(state);
        self.sender_hw_addr().hash(state);
        self.sender_protocol_addr().hash(state);
        self.target_hw_addr().hash(state);
        self.target_protocol_addr().hash(state);
    }
}

#[cfg(test)]
mod tests {
    use crate::{test_gens::*, *};
    use err::arp::{ArpHwAddrError, ArpNewError, ArpProtoAddrError};
    use proptest::prelude::*;

    #[test]
    fn new() {
        // ok case
        {
            let actual = ArpPacket::new(
                ArpHardwareId::ASH,
                EtherType::PROVIDER_BRIDGING,
                ArpOperation::REQUEST,
                &[1, 2, 3],
                &[4, 5, 6, 7, 8],
                &[9, 10, 11],
                &[12, 13, 14, 15, 16],
            )
            .unwrap();
            assert_eq!(3, actual.hw_addr_size());
            assert_eq!(5, actual.protocol_addr_size());
            assert_eq!(ArpHardwareId::ASH, actual.hw_addr_type);
            assert_eq!(EtherType::PROVIDER_BRIDGING, actual.proto_addr_type);
            assert_eq!(ArpOperation::REQUEST, actual.operation);
            assert_eq!(&[1, 2, 3], actual.sender_hw_addr());
            assert_eq!(&[4, 5, 6, 7, 8], actual.sender_protocol_addr());
            assert_eq!(&[9, 10, 11], actual.target_hw_addr());
            assert_eq!(&[12, 13, 14, 15, 16], actual.target_protocol_addr());
        }

        // ok case (upper hw size)
        {
            let actual = ArpPacket::new(
                ArpHardwareId::ASH,
                EtherType::PROVIDER_BRIDGING,
                ArpOperation::REQUEST,
                &[1; 255],
                &[4, 5, 6, 7, 8],
                &[2; 255],
                &[12, 13, 14, 15, 16],
            )
            .unwrap();
            assert_eq!(255, actual.hw_addr_size());
            assert_eq!(5, actual.protocol_addr_size());
            assert_eq!(ArpHardwareId::ASH, actual.hw_addr_type);
            assert_eq!(EtherType::PROVIDER_BRIDGING, actual.proto_addr_type);
            assert_eq!(ArpOperation::REQUEST, actual.operation);
            assert_eq!(&[1; 255], actual.sender_hw_addr());
            assert_eq!(&[4, 5, 6, 7, 8], actual.sender_protocol_addr());
            assert_eq!(&[2; 255], actual.target_hw_addr());
            assert_eq!(&[12, 13, 14, 15, 16], actual.target_protocol_addr());
        }

        // ok case (protocol hw size)
        {
            let actual = ArpPacket::new(
                ArpHardwareId::ASH,
                EtherType::PROVIDER_BRIDGING,
                ArpOperation::REQUEST,
                &[3, 4, 5],
                &[1; 255],
                &[6, 7, 8],
                &[2; 255],
            )
            .unwrap();
            assert_eq!(3, actual.hw_addr_size());
            assert_eq!(255, actual.protocol_addr_size());
            assert_eq!(ArpHardwareId::ASH, actual.hw_addr_type);
            assert_eq!(EtherType::PROVIDER_BRIDGING, actual.proto_addr_type);
            assert_eq!(ArpOperation::REQUEST, actual.operation);
            assert_eq!(&[3, 4, 5], actual.sender_hw_addr());
            assert_eq!(&[1; 255], actual.sender_protocol_addr());
            assert_eq!(&[6, 7, 8], actual.target_hw_addr());
            assert_eq!(&[2; 255], actual.target_protocol_addr());
        }

        // hw slice len differ error
        {
            let actual = ArpPacket::new(
                ArpHardwareId::ASH,
                EtherType::PROVIDER_BRIDGING,
                ArpOperation::REQUEST,
                &[1, 2, 3],
                &[],
                &[4, 5, 6, 7],
                &[],
            );
            assert_eq!(
                Err(ArpNewError::HwAddr(ArpHwAddrError::LenNonMatching(3, 4))),
                actual
            );
        }
        // protocol slice len differ error
        {
            let actual = ArpPacket::new(
                ArpHardwareId::ASH,
                EtherType::PROVIDER_BRIDGING,
                ArpOperation::REQUEST,
                &[],
                &[1, 2, 3],
                &[],
                &[4, 5, 6, 7],
            );
            assert_eq!(
                Err(ArpNewError::ProtoAddr(ArpProtoAddrError::LenNonMatching(
                    3, 4
                ))),
                actual
            );
        }

        // hardware length error
        {
            let actual = ArpPacket::new(
                ArpHardwareId::ASH,
                EtherType::PROVIDER_BRIDGING,
                ArpOperation::REQUEST,
                &[0; 256],
                &[1, 2, 3, 4],
                &[0; 256],
                &[5, 6, 7, 8],
            );
            assert_eq!(
                Err(ArpNewError::HwAddr(ArpHwAddrError::LenTooBig(256))),
                actual
            );
        }

        // protocol length error
        {
            let actual = ArpPacket::new(
                ArpHardwareId::ASH,
                EtherType::PROVIDER_BRIDGING,
                ArpOperation::REQUEST,
                &[1, 2, 3, 4],
                &[0; 256],
                &[5, 6, 7, 8],
                &[0; 256],
            );
            assert_eq!(
                Err(ArpNewError::ProtoAddr(ArpProtoAddrError::LenTooBig(256))),
                actual
            );
        }
    }

    #[test]
    fn new_unchecked() {
        // ok case
        {
            let actual = unsafe {
                ArpPacket::new_unchecked(
                    ArpHardwareId::ASH,
                    EtherType::PROVIDER_BRIDGING,
                    ArpOperation::REQUEST,
                    &[1, 2, 3],
                    &[4, 5, 6, 7, 8],
                    &[9, 10, 11],
                    &[12, 13, 14, 15, 16],
                )
            };
            assert_eq!(3, actual.hw_addr_size());
            assert_eq!(5, actual.protocol_addr_size());
            assert_eq!(ArpHardwareId::ASH, actual.hw_addr_type);
            assert_eq!(EtherType::PROVIDER_BRIDGING, actual.proto_addr_type);
            assert_eq!(ArpOperation::REQUEST, actual.operation);
            assert_eq!(&[1, 2, 3], actual.sender_hw_addr());
            assert_eq!(&[4, 5, 6, 7, 8], actual.sender_protocol_addr());
            assert_eq!(&[9, 10, 11], actual.target_hw_addr());
            assert_eq!(&[12, 13, 14, 15, 16], actual.target_protocol_addr());
        }

        // ok case (upper hw size)
        {
            let actual = unsafe {
                ArpPacket::new_unchecked(
                    ArpHardwareId::ASH,
                    EtherType::PROVIDER_BRIDGING,
                    ArpOperation::REQUEST,
                    &[0; 255],
                    &[4, 5, 6, 7, 8],
                    &[0; 255],
                    &[12, 13, 14, 15, 16],
                )
            };
            assert_eq!(255, actual.hw_addr_size());
            assert_eq!(5, actual.protocol_addr_size());
            assert_eq!(ArpHardwareId::ASH, actual.hw_addr_type);
            assert_eq!(EtherType::PROVIDER_BRIDGING, actual.proto_addr_type);
            assert_eq!(ArpOperation::REQUEST, actual.operation);
            assert_eq!(&[0; 255], actual.sender_hw_addr());
            assert_eq!(&[4, 5, 6, 7, 8], actual.sender_protocol_addr());
            assert_eq!(&[0; 255], actual.target_hw_addr());
            assert_eq!(&[12, 13, 14, 15, 16], actual.target_protocol_addr());
        }

        // ok case (protocol hw size)
        {
            let actual = ArpPacket::new(
                ArpHardwareId::ASH,
                EtherType::PROVIDER_BRIDGING,
                ArpOperation::REQUEST,
                &[1, 2, 3],
                &[0; 255],
                &[9, 10, 11],
                &[0; 255],
            )
            .unwrap();
            assert_eq!(3, actual.hw_addr_size());
            assert_eq!(255, actual.protocol_addr_size());
            assert_eq!(ArpHardwareId::ASH, actual.hw_addr_type);
            assert_eq!(EtherType::PROVIDER_BRIDGING, actual.proto_addr_type);
            assert_eq!(ArpOperation::REQUEST, actual.operation);
            assert_eq!(&[1, 2, 3], actual.sender_hw_addr());
            assert_eq!(&[0; 255], actual.sender_protocol_addr());
            assert_eq!(&[9, 10, 11], actual.target_hw_addr());
            assert_eq!(&[0; 255], actual.target_protocol_addr());
        }
    }

    proptest! {
        #[test]
        fn debug(arp in arp_packet_any()) {
            use std::format;
            assert_eq!(
                format!("{:?}", arp),
                format!(
                    "ArpPacket {{ hw_addr_type: {:?}, proto_addr_type: {:?}, hw_addr_size: {:?}, proto_addr_size: {:?}, operation: {:?}, sender_hw_addr: {:?}, sender_protocol_addr: {:?}, target_hw_addr: {:?}, target_protocol_addr: {:?} }}",
                    arp.hw_addr_type,
                    arp.proto_addr_type,
                    arp.hw_addr_size(),
                    arp.protocol_addr_size(),
                    arp.operation,
                    arp.sender_hw_addr(),
                    arp.sender_protocol_addr(),
                    arp.target_hw_addr(),
                    arp.target_protocol_addr()
                )
            );
        }
    }

    proptest! {
        #[test]
        fn clone_eq(arp in arp_packet_any()) {
            assert_eq!(&arp.clone(), &arp);
        }
    }

    proptest! {
        #[test]
        fn hash(arp in arp_packet_any()) {
            use core::hash::{Hash, Hasher};
            use std::collections::hash_map::DefaultHasher;

            let expected_hash = {
                let mut s = DefaultHasher::new();

                arp.hw_addr_type.hash(&mut s);
                arp.proto_addr_type.hash(&mut s);
                arp.hw_addr_size().hash(&mut s);
                arp.protocol_addr_size().hash(&mut s);
                arp.operation.hash(&mut s);
                arp.sender_hw_addr().hash(&mut s);
                arp.sender_protocol_addr().hash(&mut s);
                arp.target_hw_addr().hash(&mut s);
                arp.target_protocol_addr().hash(&mut s);

                s.finish()
            };

            let actual_hash = {
                let mut s = DefaultHasher::new();
                arp.hash(&mut s);
                s.finish()
            };

            assert_eq!(expected_hash, actual_hash);
        }
    }

    #[test]
    fn arp_packet_works() {
        let bytes = [
            0, 1, // hardware type
            8, 0, // proto type
            6, 4, // sizes
            0, 1, // arp operation
            0x00, 0x1b, 0x21, 0x0f, 0x91, 0x9b, // src mac
            10, 10, 1, 135, // src ip
            0xde, 0xad, 0xc0, 0x00, 0xff, 0xee, // dest mac
            192, 168, 1, 253, // dest ip
        ];

        let expected = ArpPacket::new(
            ArpHardwareId::ETHERNET,
            EtherType::IPV4,
            ArpOperation::REQUEST,
            &[0x00, 0x1b, 0x21, 0x0f, 0x91, 0x9b],
            &[10, 10, 1, 135],
            &[0xde, 0xad, 0xc0, 0x00, 0xff, 0xee],
            &[192, 168, 1, 253],
        )
        .unwrap();

        let actual = ArpPacket::from_slice(&bytes).unwrap();

        assert_eq!(expected, actual);
    }

    proptest! {
        #[test]
        fn read(
            arp in arp_packet_any()
        ) {
            use std::vec::Vec;
            use std::io::Cursor;

            // ok case
            let mut buf = Vec::with_capacity(arp.packet_len());
            arp.write(&mut buf).unwrap();
            {
                let mut cursor = Cursor::new(&buf);
                let actual = ArpPacket::read(&mut cursor).unwrap();
                assert_eq!(arp, actual);
            }

            // len io error
            for len in 0..arp.packet_len() {
                let mut cursor = Cursor::new(&buf[..len]);
                let actual = ArpPacket::read(&mut cursor);
                assert!(actual.is_err());
            }
        }
    }

    proptest! {
        #[test]
        fn write_error(
            arp in arp_packet_any()
        ) {
            use std::vec::Vec;
            use std::io::Cursor;

            let mut buf = Vec::with_capacity(arp.packet_len());
            buf.resize(arp.packet_len(), 0u8);

            // check that the write produces an error if not enough memory is present
            for len in 0..arp.packet_len() {
                let mut cursor = Cursor::new(&mut buf[..len]);
                let actual = arp.write(&mut cursor);
                assert!(actual.is_err());
            }
        }
    }

    #[test]
    fn set_hw_addrs() {
        let start = ArpPacket::new(
            ArpHardwareId::ASH,
            EtherType::PROVIDER_BRIDGING,
            ArpOperation::REQUEST,
            &[1, 2, 3],
            &[4, 5, 6, 7, 8],
            &[9, 10, 11],
            &[12, 13, 14, 15, 16],
        )
        .unwrap();

        // ok case
        {
            let mut arp = start.clone();
            arp.set_hw_addrs(&[17, 18], &[19, 20]).unwrap();
            assert_eq!(2, arp.hw_addr_size());
            assert_eq!(&[17, 18], arp.sender_hw_addr());
            assert_eq!(&[19, 20], arp.target_hw_addr());
        }

        // non matching error
        {
            let mut arp = start.clone();
            assert_eq!(
                arp.set_hw_addrs(&[17, 18], &[19]),
                Err(ArpHwAddrError::LenNonMatching(2, 1))
            );
        }

        // above 255 error
        {
            let mut arp = start.clone();
            assert_eq!(
                arp.set_hw_addrs(&[0; 260], &[0; 260]),
                Err(ArpHwAddrError::LenTooBig(260))
            );
        }
    }

    #[test]
    fn set_proto_addrs() {
        let start = ArpPacket::new(
            ArpHardwareId::ASH,
            EtherType::PROVIDER_BRIDGING,
            ArpOperation::REQUEST,
            &[1, 2, 3],
            &[4, 5, 6, 7, 8],
            &[9, 10, 11],
            &[12, 13, 14, 15, 16],
        )
        .unwrap();

        // ok case
        {
            let mut arp = start.clone();
            arp.set_protocol_addrs(&[17, 18], &[19, 20]).unwrap();
            assert_eq!(2, arp.protocol_addr_size());
            assert_eq!(&[17, 18], arp.sender_protocol_addr());
            assert_eq!(&[19, 20], arp.target_protocol_addr());
        }

        // non matching error
        {
            let mut arp = start.clone();
            assert_eq!(
                arp.set_protocol_addrs(&[17, 18], &[19]),
                Err(ArpProtoAddrError::LenNonMatching(2, 1))
            );
        }

        // above 255 error
        {
            let mut arp = start.clone();
            assert_eq!(
                arp.set_protocol_addrs(&[0; 260], &[0; 260]),
                Err(ArpProtoAddrError::LenTooBig(260))
            );
        }
    }

    proptest! {
        #[test]
        fn try_eth_ipv4(
            arp_eth_ipv4 in arp_eth_ipv4_packet_any()
        ) {
            use err::arp::ArpEthIpv4FromError::*;

            // ok case
            {
                let arp: ArpPacket = arp_eth_ipv4.clone().into();
                assert_eq!(arp.try_eth_ipv4(), Ok(arp_eth_ipv4.clone()));
            }

            // hw type error
            {
                let mut arp: ArpPacket = arp_eth_ipv4.clone().into();
                arp.hw_addr_type = ArpHardwareId::AX25;
                assert_eq!(
                    arp.try_eth_ipv4(),
                    Err(NonMatchingHwType(ArpHardwareId::AX25))
                );
            }

            // proto type error
            {
                let mut arp: ArpPacket = arp_eth_ipv4.clone().into();
                arp.proto_addr_type = EtherType::IPV6;
                assert_eq!(
                    arp.try_eth_ipv4(),
                    Err(NonMatchingProtocolType(EtherType::IPV6))
                );
            }

            // hw address size error
            {
                let mut arp: ArpPacket = arp_eth_ipv4.clone().into();
                arp.set_hw_addrs(&[1], &[2]).unwrap();
                assert_eq!(
                    arp.try_eth_ipv4(),
                    Err(NonMatchingHwAddrSize(1))
                );
            }

            // protocol address size error
            {
                let mut arp: ArpPacket = arp_eth_ipv4.clone().into();
                arp.set_protocol_addrs(&[1], &[2]).unwrap();
                assert_eq!(
                    arp.try_eth_ipv4(),
                    Err(NonMatchingProtoAddrSize(1))
                );
            }
        }
    }
}
