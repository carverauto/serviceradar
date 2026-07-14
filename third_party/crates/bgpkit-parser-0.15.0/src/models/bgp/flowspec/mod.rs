use crate::models::*;

pub mod nlri;
pub mod operators;

#[cfg(test)]
mod tests;

pub use nlri::*;
pub use operators::*;

/// Flow Specification NLRI containing an ordered list of components
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct FlowSpecNlri {
    pub components: Vec<FlowSpecComponent>,
}

/// Individual Flow-Spec component types as defined in RFC 8955/8956
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum FlowSpecComponent {
    /// Type 1: Destination Prefix
    DestinationPrefix(NetworkPrefix),
    /// Type 2: Source Prefix  
    SourcePrefix(NetworkPrefix),
    /// Type 3: IP Protocol
    IpProtocol(Vec<NumericOperator>),
    /// Type 4: Port (source OR destination)
    Port(Vec<NumericOperator>),
    /// Type 5: Destination Port
    DestinationPort(Vec<NumericOperator>),
    /// Type 6: Source Port
    SourcePort(Vec<NumericOperator>),
    /// Type 7: ICMP Type (IPv4) / ICMPv6 Type (IPv6)
    IcmpType(Vec<NumericOperator>),
    /// Type 8: ICMP Code (IPv4) / ICMPv6 Code (IPv6)
    IcmpCode(Vec<NumericOperator>),
    /// Type 9: TCP Flags
    TcpFlags(Vec<BitmaskOperator>),
    /// Type 10: Packet Length
    PacketLength(Vec<NumericOperator>),
    /// Type 11: DSCP
    Dscp(Vec<NumericOperator>),
    /// Type 12: Fragment
    Fragment(Vec<BitmaskOperator>),
    /// Type 13: Flow Label (IPv6 only)
    FlowLabel(Vec<NumericOperator>),
    /// IPv6 Destination Prefix with offset
    DestinationIpv6Prefix { offset: u8, prefix: NetworkPrefix },
    /// IPv6 Source Prefix with offset
    SourceIpv6Prefix { offset: u8, prefix: NetworkPrefix },
}

impl FlowSpecComponent {
    /// Get the numeric type identifier for this component
    pub const fn component_type(&self) -> u8 {
        match self {
            FlowSpecComponent::DestinationPrefix(_)
            | FlowSpecComponent::DestinationIpv6Prefix { .. } => 1,
            FlowSpecComponent::SourcePrefix(_) | FlowSpecComponent::SourceIpv6Prefix { .. } => 2,
            FlowSpecComponent::IpProtocol(_) => 3,
            FlowSpecComponent::Port(_) => 4,
            FlowSpecComponent::DestinationPort(_) => 5,
            FlowSpecComponent::SourcePort(_) => 6,
            FlowSpecComponent::IcmpType(_) => 7,
            FlowSpecComponent::IcmpCode(_) => 8,
            FlowSpecComponent::TcpFlags(_) => 9,
            FlowSpecComponent::PacketLength(_) => 10,
            FlowSpecComponent::Dscp(_) => 11,
            FlowSpecComponent::Fragment(_) => 12,
            FlowSpecComponent::FlowLabel(_) => 13,
        }
    }

    /// Returns true if this component uses numeric operators
    pub const fn uses_numeric_operators(&self) -> bool {
        matches!(
            self,
            FlowSpecComponent::IpProtocol(_)
                | FlowSpecComponent::Port(_)
                | FlowSpecComponent::DestinationPort(_)
                | FlowSpecComponent::SourcePort(_)
                | FlowSpecComponent::IcmpType(_)
                | FlowSpecComponent::IcmpCode(_)
                | FlowSpecComponent::PacketLength(_)
                | FlowSpecComponent::Dscp(_)
                | FlowSpecComponent::FlowLabel(_)
        )
    }

    /// Returns true if this component uses bitmask operators
    pub const fn uses_bitmask_operators(&self) -> bool {
        matches!(
            self,
            FlowSpecComponent::TcpFlags(_) | FlowSpecComponent::Fragment(_)
        )
    }
}

impl FlowSpecNlri {
    /// Create a new Flow-Spec NLRI with the given components
    pub fn new(components: Vec<FlowSpecComponent>) -> Self {
        FlowSpecNlri { components }
    }

    /// Get all components of this NLRI
    pub fn components(&self) -> &[FlowSpecComponent] {
        &self.components
    }

    /// Check if this Flow-Spec rule matches IPv4 traffic
    pub fn is_ipv4(&self) -> bool {
        self.components.iter().any(|c| {
            matches!(c,
                FlowSpecComponent::DestinationPrefix(prefix) |
                FlowSpecComponent::SourcePrefix(prefix)
                if matches!(prefix.prefix, ipnet::IpNet::V4(_))
            )
        })
    }

    /// Check if this Flow-Spec rule matches IPv6 traffic
    pub fn is_ipv6(&self) -> bool {
        self.components.iter().any(|c| {
            matches!(c,
                FlowSpecComponent::DestinationPrefix(prefix) |
                FlowSpecComponent::SourcePrefix(prefix)
                if matches!(prefix.prefix, ipnet::IpNet::V6(_))
            )
        }) || self.components.iter().any(|c| {
            matches!(
                c,
                FlowSpecComponent::DestinationIpv6Prefix { .. }
                    | FlowSpecComponent::SourceIpv6Prefix { .. }
                    | FlowSpecComponent::FlowLabel(_)
            )
        })
    }
}

/// Flow-Spec parsing and validation errors
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum FlowSpecError {
    /// Components not in ascending type order
    InvalidComponentOrder {
        expected_greater_than: u8,
        found: u8,
    },
    /// Invalid operator encoding
    InvalidOperator(u8),
    /// Invalid component type
    InvalidComponentType(u8),
    /// Insufficient data for parsing
    InsufficientData,
    /// Invalid prefix encoding
    InvalidPrefix,
    /// Invalid value length
    InvalidValueLength(u8),
}

impl std::fmt::Display for FlowSpecError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FlowSpecError::InvalidComponentOrder {
                expected_greater_than,
                found,
            } => {
                write!(
                    f,
                    "Invalid component order: expected type > {}, but found {}",
                    expected_greater_than, found
                )
            }
            FlowSpecError::InvalidOperator(op) => {
                write!(f, "Invalid operator: 0x{:02X}", op)
            }
            FlowSpecError::InvalidComponentType(t) => {
                write!(f, "Invalid component type: {}", t)
            }
            FlowSpecError::InsufficientData => {
                write!(f, "Insufficient data for parsing")
            }
            FlowSpecError::InvalidPrefix => {
                write!(f, "Invalid prefix encoding")
            }
            FlowSpecError::InvalidValueLength(len) => {
                write!(f, "Invalid value length: {}", len)
            }
        }
    }
}

impl std::error::Error for FlowSpecError {}
