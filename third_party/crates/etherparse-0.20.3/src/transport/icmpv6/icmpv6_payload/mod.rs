mod neighbor_advertisement_payload;
pub use neighbor_advertisement_payload::*;

mod neighbor_solicitation_payload;
pub use neighbor_solicitation_payload::*;

mod redirect_payload;
pub use redirect_payload::*;

mod router_advertisement_payload;
pub use router_advertisement_payload::*;

mod router_solicitation_payload;
pub use router_solicitation_payload::*;

/// Owned, structured payload data that follows the first 8 bytes of an ICMPv6 packet.
#[derive(Clone, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum Icmpv6Payload {
    /// Payload of a Router Solicitation message.
    RouterSolicitation(RouterSolicitationPayload),
    /// Payload of a Router Advertisement message.
    RouterAdvertisement(RouterAdvertisementPayload),
    /// Payload of a Neighbor Solicitation message.
    NeighborSolicitation(NeighborSolicitationPayload),
    /// Payload of a Neighbor Advertisement message.
    NeighborAdvertisement(NeighborAdvertisementPayload),
    /// Payload of a Redirect message.
    Redirect(RedirectPayload),
}

impl Icmpv6Payload {
    /// Returns the serialized payload length in bytes.
    pub fn len(&self) -> usize {
        use Icmpv6Payload::*;
        match self {
            RouterSolicitation(_) => RouterSolicitationPayload::LEN,
            RouterAdvertisement(_) => RouterAdvertisementPayload::LEN,
            NeighborSolicitation(_) => NeighborSolicitationPayload::LEN,
            NeighborAdvertisement(_) => NeighborAdvertisementPayload::LEN,
            Redirect(_) => RedirectPayload::LEN,
        }
    }

    /// Returns true if the serialized payload is empty.
    #[inline]
    pub fn is_empty(&self) -> bool {
        0 == self.len()
    }

    /// Write the fixed payload bytes to the writer.
    #[cfg(feature = "std")]
    #[cfg_attr(docsrs, doc(cfg(feature = "std")))]
    pub fn write<T: std::io::Write + Sized>(&self, writer: &mut T) -> Result<(), std::io::Error> {
        match self {
            Icmpv6Payload::RouterSolicitation(value) => writer.write_all(&value.to_bytes()),
            Icmpv6Payload::RouterAdvertisement(value) => writer.write_all(&value.to_bytes()),
            Icmpv6Payload::NeighborSolicitation(value) => writer.write_all(&value.to_bytes()),
            Icmpv6Payload::NeighborAdvertisement(value) => writer.write_all(&value.to_bytes()),
            Icmpv6Payload::Redirect(value) => writer.write_all(&value.to_bytes()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::net::Ipv6Addr;
    use proptest::prelude::*;

    #[test]
    fn router_solicitation_payload_to_bytes() {
        assert_eq!([] as [u8; 0], RouterSolicitationPayload.to_bytes());
    }

    #[test]
    fn payload_is_empty() {
        assert!(Icmpv6Payload::RouterSolicitation(RouterSolicitationPayload).is_empty());
        assert!(
            !Icmpv6Payload::RouterAdvertisement(RouterAdvertisementPayload {
                reachable_time: 1,
                retrans_timer: 2,
            })
            .is_empty()
        );
        assert!(
            !Icmpv6Payload::NeighborSolicitation(NeighborSolicitationPayload {
                target_address: Ipv6Addr::LOCALHOST,
            })
            .is_empty()
        );
        assert!(
            !Icmpv6Payload::NeighborAdvertisement(NeighborAdvertisementPayload {
                target_address: Ipv6Addr::LOCALHOST,
            })
            .is_empty()
        );
        assert!(!Icmpv6Payload::Redirect(RedirectPayload {
            target_address: Ipv6Addr::LOCALHOST,
            destination_address: Ipv6Addr::UNSPECIFIED,
        })
        .is_empty());
    }

    proptest! {
        #[test]
        fn payloads_to_bytes(
            reachable_time in any::<u32>(),
            retrans_timer in any::<u32>(),
            target_address in any::<[u8;16]>(),
            destination_address in any::<[u8;16]>()
        ) {
            let reachable_time_be = reachable_time.to_be_bytes();
            let retrans_timer_be = retrans_timer.to_be_bytes();
            let mut expected_router_advertisement = [0u8; RouterAdvertisementPayload::LEN];
            expected_router_advertisement[..4].copy_from_slice(&reachable_time_be);
            expected_router_advertisement[4..].copy_from_slice(&retrans_timer_be);

            let mut expected_redirect = [0u8; RedirectPayload::LEN];
            expected_redirect[..16].copy_from_slice(&target_address);
            expected_redirect[16..].copy_from_slice(&destination_address);

            assert_eq!(
                RouterAdvertisementPayload {
                    reachable_time,
                    retrans_timer,
                }.to_bytes(),
                expected_router_advertisement
            );
            assert_eq!(
                NeighborSolicitationPayload {
                    target_address: core::net::Ipv6Addr::from(target_address),
                }
                .to_bytes(),
                target_address
            );
            assert_eq!(
                NeighborAdvertisementPayload {
                    target_address: core::net::Ipv6Addr::from(target_address),
                }
                .to_bytes(),
                target_address
            );
            assert_eq!(
                RedirectPayload {
                    target_address: core::net::Ipv6Addr::from(target_address),
                    destination_address: core::net::Ipv6Addr::from(destination_address),
                }
                .to_bytes(),
                expected_redirect
            );
        }
    }
}
