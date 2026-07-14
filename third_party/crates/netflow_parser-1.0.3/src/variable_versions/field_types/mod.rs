//! Custom decoded field types for NetFlow V9 and IPFIX fields.
//!
//! Some flow fields encode structured data within a single integer value.
//! This module provides typed enums that decode these fields into meaningful variants,
//! similar to how [`ProtocolTypes`](crate::protocol::ProtocolTypes) decodes protocol numbers.
//!
//! # Types
//!
//! - [`ForwardingStatus`] — Decodes field ID 89 (RFC 7270) into status category and reason code.
//! - [`FragmentFlags`] — Decodes field ID 197 fragment flags bitmask.
//! - [`TcpControlBits`] — Decodes field ID 6 TCP header flags.
//! - [`Ipv6ExtensionHeaders`] — Decodes field ID 64 IPv6 extension headers bitmask.
//! - [`Ipv4Options`] — Decodes field ID 208 IPv4 options bitmask.
//! - [`TcpOptions`] — Decodes field ID 209 TCP options bitmask.
//! - [`IsMulticast`] — Decodes field ID 206 multicast indicator.
//! - [`MplsLabelExp`] — Decodes fields 203/237 MPLS experimental bits.
//! - [`FlowEndReason`] — Decodes field ID 136 flow termination reason.
//! - [`NatEvent`] — Decodes field ID 230 NAT event type.
//! - [`FirewallEvent`] — Decodes field ID 233 firewall event.
//! - [`MplsTopLabelType`] — Decodes field ID 46 MPLS label type.
//! - [`NatOriginatingAddressRealm`] — Decodes field ID 229 NAT address realm.

mod firewall_event;
mod flow_end_reason;
mod forwarding_status;
mod fragment_flags;
mod ipv4_options;
mod ipv6_extension_headers;
mod is_multicast;
mod mpls_label_exp;
mod mpls_top_label_type;
mod nat_event;
mod nat_originating_address_realm;
mod tcp_control_bits;
mod tcp_options;

pub use firewall_event::FirewallEvent;
pub use flow_end_reason::FlowEndReason;
pub use forwarding_status::ForwardingStatus;
pub use fragment_flags::FragmentFlags;
pub use ipv4_options::Ipv4Options;
pub use ipv6_extension_headers::Ipv6ExtensionHeaders;
pub use is_multicast::IsMulticast;
pub use mpls_label_exp::MplsLabelExp;
pub use mpls_top_label_type::MplsTopLabelType;
pub use nat_event::NatEvent;
pub use nat_originating_address_realm::NatOriginatingAddressRealm;
pub use tcp_control_bits::TcpControlBits;
pub use tcp_options::TcpOptions;
