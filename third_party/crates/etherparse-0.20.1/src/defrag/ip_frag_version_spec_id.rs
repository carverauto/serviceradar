/// IPv4 & IPv6 specific fragment identifying information.
#[derive(Debug, Clone, Hash, Eq, PartialEq)]
pub enum IpFragVersionSpecId {
    /// IPv4 specific data.
    Ipv4 {
        source: [u8; 4],
        destination: [u8; 4],
        identification: u16,
    },
    /// IPv6 specific data.
    Ipv6 {
        source: [u8; 16],
        destination: [u8; 16],
        identification: u32,
    },
}
