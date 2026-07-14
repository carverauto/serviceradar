use num_enum::{IntoPrimitive, TryFromPrimitive};
use std::net::IpAddr;

/// AFI -- Address Family Identifier
///
/// <https://www.iana.org/assignments/address-family-numbers/address-family-numbers.xhtml>
#[derive(Debug, PartialEq, TryFromPrimitive, IntoPrimitive, Clone, Copy, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum Afi {
    Ipv4 = 1,
    Ipv6 = 2,
    /// BGP Link-State - RFC 7752
    LinkState = 16388,
}

impl From<IpAddr> for Afi {
    #[inline]
    fn from(value: IpAddr) -> Self {
        match value {
            IpAddr::V4(_) => Afi::Ipv4,
            IpAddr::V6(_) => Afi::Ipv6,
        }
    }
}

/// SAFI -- Subsequent Address Family Identifier
///
/// SAFI can be: Unicast, Multicast, or both, as well as MPLS VPN variants.
/// The AFI determines the IP version (IPv4/IPv6), while SAFI determines the application.
///
/// References:
/// - RFC 4760: Multiprotocol Extensions for BGP-4
/// - RFC 4364: BGP/MPLS IP Virtual Private Networks (VPNs) - defines SAFI 128
/// - RFC 6514: BGP Signaling of Multicast VPNs - defines SAFI 129
/// - RFC 7752: BGP Link-State - defines SAFI 71, 72
/// - RFC 8950: Advertising IPv4 Network Layer Reachability Information (NLRI) with an IPv6 Next Hop
#[derive(Debug, PartialEq, TryFromPrimitive, IntoPrimitive, Clone, Copy, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum Safi {
    Unicast = 1,
    Multicast = 2,
    UnicastMulticast = 3,
    /// BGP Link-State - RFC 7752
    LinkState = 71,
    /// BGP Link-State VPN - RFC 7752
    LinkStateVpn = 72,
    /// MPLS-labeled VPN address - RFC 4364, used in RFC 8950 Section 4
    /// Works with both AFI 1 (VPN-IPv4) and AFI 2 (VPN-IPv6)
    MplsVpn = 128,
    /// Multicast for BGP/MPLS IP VPNs - RFC 6514
    /// Works with both AFI 1 (Multicast VPN-IPv4) and AFI 2 (Multicast VPN-IPv6)
    MulticastVpn = 129,
    /// Flow Specification - RFC 8955/8956
    /// Works with both AFI 1 (IPv4 Flow-Spec) and AFI 2 (IPv6 Flow-Spec)
    FlowSpec = 133,
    /// L3VPN Flow Specification - RFC 8955/8956
    /// Works with both AFI 1 (VPN-IPv4 Flow-Spec) and AFI 2 (VPN-IPv6 Flow-Spec)
    FlowSpecL3Vpn = 134,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_afi_from() {
        assert_eq!(
            Afi::from(IpAddr::V4(std::net::Ipv4Addr::new(127, 0, 0, 1))),
            Afi::Ipv4
        );
        assert_eq!(
            Afi::from(IpAddr::V6(std::net::Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 1))),
            Afi::Ipv6
        );
    }

    #[test]
    fn test_afi_safi_repr() {
        assert_eq!(Afi::Ipv4 as u16, 1);
        assert_eq!(Afi::Ipv6 as u16, 2);
        assert_eq!(Afi::LinkState as u16, 16388);

        assert_eq!(Safi::Unicast as u8, 1);
        assert_eq!(Safi::Multicast as u8, 2);
        assert_eq!(Safi::UnicastMulticast as u8, 3);
        // RFC 7752 Link-State SAFI values
        assert_eq!(Safi::LinkState as u8, 71);
        assert_eq!(Safi::LinkStateVpn as u8, 72);
        // RFC 8950 VPN SAFI values
        assert_eq!(Safi::MplsVpn as u8, 128);
        assert_eq!(Safi::MulticastVpn as u8, 129);
        // RFC 8955/8956 Flow-Spec SAFI values
        assert_eq!(Safi::FlowSpec as u8, 133);
        assert_eq!(Safi::FlowSpecL3Vpn as u8, 134);
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_afi_safi_serde() {
        let afi = Afi::Ipv4;
        let serialized = serde_json::to_string(&afi).unwrap();
        assert_eq!(serialized, "\"Ipv4\"");
        let deserialized: Afi = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, afi);

        let afi = Afi::Ipv6;
        let serialized = serde_json::to_string(&afi).unwrap();
        assert_eq!(serialized, "\"Ipv6\"");
        let deserialized: Afi = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, afi);

        let safi = Safi::Unicast;
        let serialized = serde_json::to_string(&safi).unwrap();
        assert_eq!(serialized, "\"Unicast\"");
        let deserialized: Safi = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, safi);

        let safi = Safi::Multicast;
        let serialized = serde_json::to_string(&safi).unwrap();
        assert_eq!(serialized, "\"Multicast\"");
        let deserialized: Safi = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, safi);

        let safi = Safi::UnicastMulticast;
        let serialized = serde_json::to_string(&safi).unwrap();
        assert_eq!(serialized, "\"UnicastMulticast\"");
        let deserialized: Safi = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, safi);

        // RFC 8950 VPN SAFI variants
        let safi = Safi::MplsVpn;
        let serialized = serde_json::to_string(&safi).unwrap();
        assert_eq!(serialized, "\"MplsVpn\"");
        let deserialized: Safi = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, safi);

        let safi = Safi::MulticastVpn;
        let serialized = serde_json::to_string(&safi).unwrap();
        assert_eq!(serialized, "\"MulticastVpn\"");
        let deserialized: Safi = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, safi);

        // RFC 8955/8956 Flow-Spec SAFI variants
        let safi = Safi::FlowSpec;
        let serialized = serde_json::to_string(&safi).unwrap();
        assert_eq!(serialized, "\"FlowSpec\"");
        let deserialized: Safi = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, safi);

        let safi = Safi::FlowSpecL3Vpn;
        let serialized = serde_json::to_string(&safi).unwrap();
        assert_eq!(serialized, "\"FlowSpecL3Vpn\"");
        let deserialized: Safi = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, safi);
    }
}
