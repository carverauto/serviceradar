use std::fmt::{Debug, Display, Formatter};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Route Distinguisher for VPN next-hops - RFC 4364, Section 4.1
/// An 8-byte value used to distinguish VPN routes with potentially overlapping address spaces
#[derive(PartialEq, Copy, Clone, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RouteDistinguisher(pub [u8; 8]);

impl Debug for RouteDistinguisher {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "RD({:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x})",
            self.0[0], self.0[1], self.0[2], self.0[3], self.0[4], self.0[5], self.0[6], self.0[7]
        )
    }
}

impl Display for RouteDistinguisher {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
            self.0[0], self.0[1], self.0[2], self.0[3], self.0[4], self.0[5], self.0[6], self.0[7]
        )
    }
}

/// enum that represents the type of the next hop address.
///
/// [NextHopAddress] is used when parsing for next hops in [Nlri](crate::models::Nlri).
/// RFC 8950 extends this to support VPN next-hops with Route Distinguishers.
#[derive(PartialEq, Copy, Clone, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum NextHopAddress {
    Ipv4(Ipv4Addr),
    Ipv6(Ipv6Addr),
    Ipv6LinkLocal(Ipv6Addr, Ipv6Addr),
    /// VPN-IPv6 next hop - RFC 8950, Section 4
    /// Contains Route Distinguisher (8 bytes) + IPv6 address (16 bytes) = 24 bytes total
    VpnIpv6(RouteDistinguisher, Ipv6Addr),
    /// VPN-IPv6 next hop with link-local - RFC 8950, Section 4  
    /// Contains RD (8 bytes) + IPv6 (16 bytes) + RD (8 bytes) + IPv6 link-local (16 bytes) = 48 bytes total
    VpnIpv6LinkLocal(RouteDistinguisher, Ipv6Addr, RouteDistinguisher, Ipv6Addr),
}

impl NextHopAddress {
    /// Returns true if the next hop is a link local address
    pub const fn is_link_local(&self) -> bool {
        match self {
            NextHopAddress::Ipv4(x) => x.is_link_local(),
            NextHopAddress::Ipv6(x) => (x.segments()[0] & 0xffc0) == 0xfe80,
            NextHopAddress::Ipv6LinkLocal(_, _) => true,
            NextHopAddress::VpnIpv6(_, x) => (x.segments()[0] & 0xffc0) == 0xfe80,
            NextHopAddress::VpnIpv6LinkLocal(_, _, _, _) => true,
        }
    }

    /// Returns the address that this next hop points to
    pub const fn addr(&self) -> IpAddr {
        match self {
            NextHopAddress::Ipv4(x) => IpAddr::V4(*x),
            NextHopAddress::Ipv6(x) => IpAddr::V6(*x),
            NextHopAddress::Ipv6LinkLocal(x, _) => IpAddr::V6(*x),
            NextHopAddress::VpnIpv6(_, x) => IpAddr::V6(*x),
            NextHopAddress::VpnIpv6LinkLocal(_, x, _, _) => IpAddr::V6(*x),
        }
    }
}

// Attempt to reduce the size of the debug output
impl Debug for NextHopAddress {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            NextHopAddress::Ipv4(x) => write!(f, "{x}"),
            NextHopAddress::Ipv6(x) => write!(f, "{x}"),
            NextHopAddress::Ipv6LinkLocal(x, y) => write!(f, "Ipv6LinkLocal({x}, {y})"),
            NextHopAddress::VpnIpv6(rd, x) => write!(f, "VpnIpv6({rd}, {x})"),
            NextHopAddress::VpnIpv6LinkLocal(rd1, x, rd2, y) => {
                write!(f, "VpnIpv6LinkLocal({rd1}, {x}, {rd2}, {y})")
            }
        }
    }
}

impl Display for NextHopAddress {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            NextHopAddress::Ipv4(v) => write!(f, "{v}"),
            NextHopAddress::Ipv6(v) => write!(f, "{v}"),
            NextHopAddress::Ipv6LinkLocal(v, _) => write!(f, "{v}"),
            NextHopAddress::VpnIpv6(_, v) => write!(f, "{v}"),
            NextHopAddress::VpnIpv6LinkLocal(_, v, _, _) => write!(f, "{v}"),
        }
    }
}

impl From<IpAddr> for NextHopAddress {
    fn from(value: IpAddr) -> Self {
        match value {
            IpAddr::V4(x) => NextHopAddress::Ipv4(x),
            IpAddr::V6(x) => NextHopAddress::Ipv6(x),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    #[test]
    fn test_next_hop_address_is_link_local() {
        let ipv4_addr = Ipv4Addr::new(169, 254, 0, 1);
        let ipv6_addr = Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 0);
        let ipv6_link_local_addrs = (
            Ipv6Addr::new(0xfe80, 0, 0, 1, 0, 0, 0, 1),
            Ipv6Addr::new(0xfe80, 0, 0, 2, 0, 0, 0, 1),
        );

        let next_hop_ipv4 = NextHopAddress::Ipv4(ipv4_addr);
        let next_hop_ipv6 = NextHopAddress::Ipv6(ipv6_addr);
        let next_hop_ipv6_link_local =
            NextHopAddress::Ipv6LinkLocal(ipv6_link_local_addrs.0, ipv6_link_local_addrs.1);

        assert!(next_hop_ipv4.is_link_local());
        assert!(next_hop_ipv6.is_link_local());
        assert!(next_hop_ipv6_link_local.is_link_local());
    }

    #[test]
    fn test_next_hop_address_addr() {
        let ipv4_addr = Ipv4Addr::new(192, 0, 2, 1);
        let ipv6_addr = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);
        let ipv6_link_local_addrs = (
            Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
            Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
        );

        let next_hop_ipv4 = NextHopAddress::Ipv4(ipv4_addr);
        let next_hop_ipv6 = NextHopAddress::Ipv6(ipv6_addr);
        let next_hop_ipv6_link_local =
            NextHopAddress::Ipv6LinkLocal(ipv6_link_local_addrs.0, ipv6_link_local_addrs.1);

        assert_eq!(next_hop_ipv4.addr(), IpAddr::V4(ipv4_addr));
        assert_eq!(next_hop_ipv6.addr(), IpAddr::V6(ipv6_addr));
        assert_eq!(
            next_hop_ipv6_link_local.addr(),
            IpAddr::V6(ipv6_link_local_addrs.0)
        );
    }

    #[test]
    fn test_next_hop_address_from() {
        let ipv4_addr = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1));
        let ipv6_addr = IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1));

        let next_hop_ipv4 = NextHopAddress::from(ipv4_addr);
        let next_hop_ipv6 = NextHopAddress::from(ipv6_addr);

        assert_eq!(next_hop_ipv4.addr(), ipv4_addr);
        assert_eq!(next_hop_ipv6.addr(), ipv6_addr);
    }

    #[test]
    fn test_debug_for_next_hop_address() {
        let ipv4_addr = Ipv4Addr::new(192, 0, 2, 1);
        let ipv6_addr = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);
        let ipv6_link_local_addrs = (
            Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
            Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
        );

        let next_hop_ipv4 = NextHopAddress::Ipv4(ipv4_addr);
        let next_hop_ipv6 = NextHopAddress::Ipv6(ipv6_addr);
        let next_hop_ipv6_link_local =
            NextHopAddress::Ipv6LinkLocal(ipv6_link_local_addrs.0, ipv6_link_local_addrs.1);

        assert_eq!(format!("{next_hop_ipv4:?}"), "192.0.2.1");
        assert_eq!(format!("{next_hop_ipv6:?}"), "2001:db8::1");
        assert_eq!(
            format!("{next_hop_ipv6_link_local:?}"),
            "Ipv6LinkLocal(fe80::, fe80::)"
        );
    }

    #[test]
    fn test_display_for_next_hop_address() {
        let ipv4_addr = Ipv4Addr::new(192, 0, 2, 1);
        let ipv6_addr = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);
        let ipv6_link_local_addrs = (
            Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
            Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 0),
        );

        let next_hop_ipv4 = NextHopAddress::Ipv4(ipv4_addr);
        let next_hop_ipv6 = NextHopAddress::Ipv6(ipv6_addr);
        let next_hop_ipv6_link_local =
            NextHopAddress::Ipv6LinkLocal(ipv6_link_local_addrs.0, ipv6_link_local_addrs.1);

        assert_eq!(format!("{next_hop_ipv4}"), "192.0.2.1");
        assert_eq!(format!("{next_hop_ipv6}"), "2001:db8::1");
        assert_eq!(format!("{next_hop_ipv6_link_local}"), "fe80::");
    }

    #[test]
    fn test_route_distinguisher() {
        let rd = RouteDistinguisher([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]);

        // Test Debug format
        assert_eq!(format!("{rd:?}"), "RD(00:01:02:03:04:05:06:07)");

        // Test Display format
        assert_eq!(format!("{rd}"), "00:01:02:03:04:05:06:07");
    }

    #[test]
    fn test_vpn_next_hop_address() {
        let rd = RouteDistinguisher([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]);
        let ipv6_addr = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);
        let ipv6_link_local = Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
        let rd2 = RouteDistinguisher([0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17]);

        // Test VpnIpv6
        let vpn_next_hop = NextHopAddress::VpnIpv6(rd, ipv6_addr);
        assert_eq!(vpn_next_hop.addr(), IpAddr::V6(ipv6_addr));
        assert!(!vpn_next_hop.is_link_local());
        assert_eq!(format!("{vpn_next_hop}"), "2001:db8::1");
        assert_eq!(
            format!("{vpn_next_hop:?}"),
            "VpnIpv6(00:01:02:03:04:05:06:07, 2001:db8::1)"
        );

        // Test VpnIpv6LinkLocal
        let vpn_ll_next_hop = NextHopAddress::VpnIpv6LinkLocal(rd, ipv6_addr, rd2, ipv6_link_local);
        assert_eq!(vpn_ll_next_hop.addr(), IpAddr::V6(ipv6_addr));
        assert!(vpn_ll_next_hop.is_link_local()); // Should return true for VpnIpv6LinkLocal
        assert_eq!(format!("{vpn_ll_next_hop}"), "2001:db8::1");
        assert_eq!(format!("{vpn_ll_next_hop:?}"), "VpnIpv6LinkLocal(00:01:02:03:04:05:06:07, 2001:db8::1, 10:11:12:13:14:15:16:17, fe80::1)");

        // Test VpnIpv6 with link-local IP (not VpnIpv6LinkLocal variant)
        let vpn_ll_ip = NextHopAddress::VpnIpv6(rd, ipv6_link_local);
        assert!(vpn_ll_ip.is_link_local()); // Should detect link-local from IPv6 address
    }
}
