use crate::err::packet::BuildSliceWriteError;
#[cfg(feature = "alloc")]
use crate::err::packet::BuildVecWriteError;
#[cfg(feature = "std")]
use crate::err::packet::BuildWriteError;

use super::*;

use core::marker;

#[cfg(feature = "alloc")]
use alloc::vec::Vec;

impl From<SliceCoreWriteError> for BuildSliceWriteError {
    fn from(value: SliceCoreWriteError) -> Self {
        BuildSliceWriteError::Space(value.required_len)
    }
}

impl From<crate::WriteError<SliceCoreWriteError, err::ipv4_exts::ExtsWalkError>>
    for BuildSliceWriteError
{
    fn from(value: crate::WriteError<SliceCoreWriteError, err::ipv4_exts::ExtsWalkError>) -> Self {
        match value {
            crate::WriteError::Io(err) => err.into(),
            crate::WriteError::Content(err) => BuildSliceWriteError::Ipv4Exts(err),
        }
    }
}

impl From<crate::WriteError<SliceCoreWriteError, err::ipv6_exts::ExtsWalkError>>
    for BuildSliceWriteError
{
    fn from(value: crate::WriteError<SliceCoreWriteError, err::ipv6_exts::ExtsWalkError>) -> Self {
        match value {
            crate::WriteError::Io(err) => err.into(),
            crate::WriteError::Content(err) => BuildSliceWriteError::Ipv6Exts(err),
        }
    }
}

fn final_write_to_slice<B>(
    builder: PacketBuilderStep<B>,
    buffer: &mut [u8],
    payload: &[u8],
) -> Result<usize, BuildSliceWriteError> {
    let required = final_size(&builder, payload.len());
    let slice = buffer
        .get_mut(..required)
        .ok_or(BuildSliceWriteError::Space(required))?;

    let mut writer = SliceCoreWrite::new(slice);
    final_write_with_net::<_, _, BuildSliceWriteError>(builder, &mut writer, payload)?;
    Ok(required)
}

/// Helper for building packets.
///
/// The packet builder allows the easy construction of a packet from the
/// ethernet II layer downwards including ipv6, ipv4, the udp header and the
/// actual payload. The packet builder automatically calculates lengths & checksums
/// for ip & udp and set type identifiers for ethernetII and ip. This makes it
/// easy and less error prone to construct custom packets.
///
/// # Example:
///
/// Generating a packet that starts with an Ethernet II header:
///
/// ```
/// use etherparse::PacketBuilder;
///
/// let builder = PacketBuilder::
///     ethernet2([1,2,3,4,5,6],     //source mac
///               [7,8,9,10,11,12]) //destination mac
///    .ipv4([192,168,1,1], //source ip
///          [192,168,1,2], //destination ip
///          20)            //time to life
///    .udp(21,    //source port
///         1234); //destination port
///
/// //payload of the udp packet
/// let payload = [1,2,3,4,5,6,7,8];
///
/// //get some memory to store the result
/// let mut result = Vec::<u8>::with_capacity(
///                     builder.size(payload.len()));
///
/// //serialize
/// builder.write(&mut result, &payload).unwrap();
/// println!("{:?}", result);
/// ```
///
/// # Options
///
/// * Starting Options:
///     * [`PacketBuilder::ethernet2`]
///     * [`PacketBuilder::linux_sll`]
///     * [`PacketBuilder::ip`]
///     * [`PacketBuilder::ipv4`]
///     * [`PacketBuilder::ipv6`]
/// * Options after an Ethernet2 header was added:
///     * [`PacketBuilderStep<Ethernet2Header>::arp`]
///     * [`PacketBuilderStep<Ethernet2Header>::vlan`]
///     * [`PacketBuilderStep<Ethernet2Header>::single_vlan`]
///     * [`PacketBuilderStep<Ethernet2Header>::double_vlan`]
///     * [`PacketBuilderStep<Ethernet2Header>::ip`]
///     * [`PacketBuilderStep<Ethernet2Header>::ipv4`]
///     * [`PacketBuilderStep<Ethernet2Header>::ipv6`]
/// * Options after a Linux Cooked Capture v1 (SLL) was added:
///     * [`PacketBuilderStep<LinuxSllHeader>::ip`]
///     * [`PacketBuilderStep<LinuxSllHeader>::ipv4`]
///     * [`PacketBuilderStep<LinuxSllHeader>::ipv6`]
/// * Options after an Vlan header was added:
///     * [`PacketBuilderStep<VlanHeader>::ip`]
///     * [`PacketBuilderStep<VlanHeader>::ipv4`]
///     * [`PacketBuilderStep<VlanHeader>::ipv6`]
/// * Options after an IP header was added:
///     * [`PacketBuilderStep<IpHeaders>::write`]
///     * [`PacketBuilderStep<IpHeaders>::tcp`]
///     * [`PacketBuilderStep<IpHeaders>::udp`]
///     * [`PacketBuilderStep<IpHeaders>::icmpv4`]
///     * [`PacketBuilderStep<IpHeaders>::icmpv4_raw`]
///     * [`PacketBuilderStep<IpHeaders>::icmpv4_echo_request`]
///     * [`PacketBuilderStep<IpHeaders>::icmpv4_echo_reply`]
///     * [`PacketBuilderStep<IpHeaders>::icmpv6`]
///     * [`PacketBuilderStep<IpHeaders>::icmpv6_raw`]
///     * [`PacketBuilderStep<IpHeaders>::icmpv6_echo_request`]
///     * [`PacketBuilderStep<IpHeaders>::icmpv6_echo_reply`]
/// * Options after an TCP header was added:
///     * [`PacketBuilderStep<TcpHeader>::write`]
///     * [`PacketBuilderStep<TcpHeader>::size`]
///     * [`PacketBuilderStep<TcpHeader>::ns`]
///     * [`PacketBuilderStep<TcpHeader>::fin`]
///     * [`PacketBuilderStep<TcpHeader>::syn`]
///     * [`PacketBuilderStep<TcpHeader>::rst`]
///     * [`PacketBuilderStep<TcpHeader>::psh`]
///     * [`PacketBuilderStep<TcpHeader>::ack`]
///     * [`PacketBuilderStep<TcpHeader>::urg`]
///     * [`PacketBuilderStep<TcpHeader>::ece`]
///     * [`PacketBuilderStep<TcpHeader>::cwr`]
///     * [`PacketBuilderStep<TcpHeader>::options`]
///     * [`PacketBuilderStep<TcpHeader>::options_raw`]
/// * Options after an UDP header was added:
///     * [`PacketBuilderStep<UdpHeader>::write`]
///     * [`PacketBuilderStep<UdpHeader>::size`]
/// * Options after an ICMPv4 header was added:
///     * [`PacketBuilderStep<Icmpv4Header>::write`]
///     * [`PacketBuilderStep<Icmpv4Header>::size`]
/// * Options after an ICMPv6 header was added:
///     * [`PacketBuilderStep<Icmpv6Header>::write`]
///     * [`PacketBuilderStep<Icmpv6Header>::size`]
///
pub struct PacketBuilder {}

impl PacketBuilder {
    /// Start an packet with an ethernetII header.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],     //source mac
    ///               [7,8,9,10,11,12]) //destination mac
    ///    .ipv4([192,168,1,1], //source ip
    ///          [192,168,1,2], //destination ip
    ///          20)            //time to life
    ///    .udp(21,    //source port
    ///         1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn ethernet2(source: [u8; 6], destination: [u8; 6]) -> PacketBuilderStep<Ethernet2Header> {
        PacketBuilderStep {
            state: PacketImpl {
                link_header: Some(LinkHeader::Ethernet2(Ethernet2Header {
                    source,
                    destination,
                    ether_type: EtherType(0), //the type identifier
                })),
                vlan_header: None,
                net_header: None,
                transport_header: None,
            },
            _marker: marker::PhantomData::<Ethernet2Header> {},
        }
    }

    /// Start an packet with an Linux Cooked Capture (v1) header.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::{PacketBuilder, LinuxSllPacketType};
    /// #
    /// let builder = PacketBuilder::
    ///     linux_sll(LinuxSllPacketType::OTHERHOST, //packet type
    ///               6, //sender address valid length
    ///               [1,2,3,4,5,6,0,0]) //sender address with padding
    ///    .ipv4([192,168,1,1], //source ip
    ///          [192,168,1,2], //destination ip
    ///          20)            //time to life
    ///    .udp(21,    //source port
    ///         1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn linux_sll(
        packet_type: LinuxSllPacketType,
        sender_address_valid_length: u16,
        sender_address: [u8; 8],
    ) -> PacketBuilderStep<LinuxSllHeader> {
        PacketBuilderStep {
            state: PacketImpl {
                link_header: Some(LinkHeader::LinuxSll(LinuxSllHeader {
                    packet_type,
                    arp_hrd_type: ArpHardwareId::ETHERNET,
                    sender_address_valid_length,
                    sender_address,
                    protocol_type: LinuxSllProtocolType::EtherType(EtherType(0)), // Will be overwritten when writing depending on the net layer
                })),
                vlan_header: None,
                net_header: None,
                transport_header: None,
            },
            _marker: marker::PhantomData::<LinuxSllHeader> {},
        }
    }

    /// Starts a packet with an IPv4 header.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///    ipv4([192,168,1,1],  //source ip
    ///          [192,168,1,2], //destination ip
    ///          20)            //time to life
    ///    .udp(21,    //source port
    ///         1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///     
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn ipv4(
        source: [u8; 4],
        destination: [u8; 4],
        time_to_live: u8,
    ) -> PacketBuilderStep<IpHeaders> {
        PacketBuilderStep {
            state: PacketImpl {
                link_header: None,
                vlan_header: None,
                net_header: None,
                transport_header: None,
            },
            _marker: marker::PhantomData::<Ethernet2Header> {},
        }
        .ipv4(source, destination, time_to_live)
    }

    /// Start a packet with an IPv6 header.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///     ipv6(
    ///         //source
    ///         [11,12,13,14,15,16,17,18,19,10,21,22,23,24,25,26],
    ///         //destination
    ///         [31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46],
    ///         //hop_limit
    ///         47)
    ///    .udp(21,    //source port
    ///         1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn ipv6(
        source: [u8; 16],
        destination: [u8; 16],
        hop_limit: u8,
    ) -> PacketBuilderStep<IpHeaders> {
        PacketBuilderStep {
            state: PacketImpl {
                link_header: None,
                vlan_header: None,
                net_header: None,
                transport_header: None,
            },
            _marker: marker::PhantomData::<Ethernet2Header> {},
        }
        .ipv6(source, destination, hop_limit)
    }

    /// Starts a packet with an arbitrary IP header (length, protocol/next_header & checksum fields will be overwritten based on the rest of the packet).
    ///
    /// # Examples
    ///
    /// With an IPv4 header:
    ///
    /// ```
    /// # use etherparse::*;
    /// #
    /// let builder = PacketBuilder::
    ///    //payload_len, protocol & checksum will be replaced during write
    ///    ip(IpHeaders::Ipv4(
    ///        Ipv4Header::new(
    ///            0, //payload_len will be replaced during write
    ///            12, //time_to_live
    ///            ip_number::UDP, //will be replaced during write
    ///            [0,1,2,3], //source
    ///            [4,5,6,7] //destination
    ///        ).unwrap(),
    ///        Default::default()))
    ///    .udp(21,    //source port
    ///         1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    ///
    /// With an IPv6 header:
    ///
    /// ```
    /// # use etherparse::*;
    /// #
    /// let builder = PacketBuilder::
    ///    ip(IpHeaders::Ipv6(
    ///         Ipv6Header{
    ///             traffic_class: 0,
    ///             flow_label: 0.try_into().unwrap(),
    ///             hop_limit: 4.try_into().unwrap(),
    ///             source: [0;16],
    ///             destination: [0;16],
    ///             // payload_length & next_header will be replaced during write
    ///             ..Default::default()
    ///         },
    ///         Default::default()))
    ///    .udp(21,    //source port
    ///         1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///     
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn ip(ip_header: IpHeaders) -> PacketBuilderStep<IpHeaders> {
        PacketBuilderStep {
            state: PacketImpl {
                link_header: None,
                vlan_header: None,
                net_header: None,
                transport_header: None,
            },
            _marker: marker::PhantomData::<Ethernet2Header> {},
        }
        .ip(ip_header)
    }
}

struct PacketImpl {
    link_header: Option<LinkHeader>,
    net_header: Option<NetHeaders>,
    vlan_header: Option<VlanHeader>,
    transport_header: Option<TransportHeader>,
}

///An unfinished packet that is build with the packet builder
pub struct PacketBuilderStep<LastStep> {
    state: PacketImpl,
    _marker: marker::PhantomData<LastStep>,
}

impl PacketBuilderStep<Ethernet2Header> {
    /// Add an IPv4 header
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],     //source mac
    ///               [7,8,9,10,11,12]) //destination mac
    ///    .ipv4([192,168,1,1], //source ip
    ///          [192,168,1,2], //destination ip
    ///          20)            //time to life
    ///    .udp(21,    //source port
    ///         1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn ipv4(
        mut self,
        source: [u8; 4],
        destination: [u8; 4],
        time_to_live: u8,
    ) -> PacketBuilderStep<IpHeaders> {
        //add ip header
        self.state.net_header = Some(NetHeaders::Ipv4(
            Ipv4Header {
                source,
                destination,
                time_to_live,
                ..Default::default()
            },
            Default::default(),
        ));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<IpHeaders> {},
        }
    }

    /// Add an IP header (length, protocol/next_header & checksum fields will be overwritten based on the rest of the packet).
    ///
    /// # Examples
    ///
    /// With an IPv4 header:
    ///
    /// ```
    /// # use etherparse::*;
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],
    ///               [7,8,9,10,11,12])
    ///    //payload_len, protocol & checksum will be replaced during write
    ///    .ip(IpHeaders::Ipv4(
    ///        Ipv4Header::new(
    ///            0, //payload_len will be replaced during write
    ///            12, //time_to_live
    ///            ip_number::UDP, //will be replaced during write
    ///            [0,1,2,3], //source
    ///            [4,5,6,7] //destination
    ///        ).unwrap(),
    ///        Default::default()));
    /// ```
    ///
    /// With an IPv6 header:
    ///
    /// ```
    /// # use etherparse::*;
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],
    ///               [7,8,9,10,11,12])
    ///    .ip(IpHeaders::Ipv6(
    ///         Ipv6Header{
    ///             traffic_class: 0,
    ///             flow_label: 0.try_into().unwrap(),
    ///             hop_limit: 4,
    ///             source: [0;16],
    ///             destination: [0;16],
    ///             // payload_length & next_header will be replaced during write
    ///             ..Default::default()
    ///         },
    ///         Default::default()));
    /// ```
    pub fn ip(mut self, ip_header: IpHeaders) -> PacketBuilderStep<IpHeaders> {
        //add ip header
        self.state.net_header = Some(match ip_header {
            IpHeaders::Ipv4(header, exts) => NetHeaders::Ipv4(header, exts),
            IpHeaders::Ipv6(header, exts) => NetHeaders::Ipv6(header, exts),
        });
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<IpHeaders> {},
        }
    }

    /// Add an IPv6 header
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],
    ///               [7,8,9,10,11,12])
    ///     .ipv6(
    ///         //source
    ///         [11,12,13,14,15,16,17,18,19,10,21,22,23,24,25,26],
    ///         //destination
    ///         [31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46],
    ///         //hop_limit
    ///         47)
    ///    .udp(21,    //source port
    ///         1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn ipv6(
        mut self,
        source: [u8; 16],
        destination: [u8; 16],
        hop_limit: u8,
    ) -> PacketBuilderStep<IpHeaders> {
        self.state.net_header = Some(NetHeaders::Ipv6(
            Ipv6Header {
                traffic_class: 0,
                flow_label: Ipv6FlowLabel::ZERO,
                payload_length: 0,          //filled in on write
                next_header: IpNumber(255), //filled in on write
                hop_limit,
                source,
                destination,
            },
            Default::default(),
        ));

        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<IpHeaders> {},
        }
    }

    /// Adds a vlan tagging header with the given vlan identifier
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::{PacketBuilder, SingleVlanHeader, VlanHeader};
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],     //source mac
    ///               [7,8,9,10,11,12]) //destination mac
    ///     .vlan(VlanHeader::Single(
    ///         SingleVlanHeader{
    ///             pcp: 1.try_into().unwrap(),
    ///             drop_eligible_indicator: false,
    ///             vlan_id: 0x123.try_into().unwrap(),
    ///             ether_type: 0.into() // will be overwritten during write
    ///         }))
    ///     .ipv4([192,168,1,1], //source ip
    ///           [192,168,1,2], //destination ip
    ///           20)            //time to life
    ///     .udp(21,    //source port
    ///          1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn vlan(mut self, vlan: VlanHeader) -> PacketBuilderStep<VlanHeader> {
        self.state.vlan_header = Some(vlan);
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<VlanHeader> {},
        }
    }

    /// Adds a vlan tagging header with the given vlan identifier
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::{PacketBuilder, SingleVlanHeader, VlanHeader};
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],     //source mac
    ///               [7,8,9,10,11,12]) //destination mac
    ///     .single_vlan(0x123.try_into().unwrap()) // vlan identifier
    ///     .ipv4([192,168,1,1], //source ip
    ///           [192,168,1,2], //destination ip
    ///           20)            //time to life
    ///     .udp(21,    //source port
    ///          1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn single_vlan(mut self, vlan_identifier: VlanId) -> PacketBuilderStep<VlanHeader> {
        self.state.vlan_header = Some(VlanHeader::Single(SingleVlanHeader {
            pcp: VlanPcp::ZERO,
            drop_eligible_indicator: false,
            vlan_id: vlan_identifier,
            ether_type: EtherType(0), //will be set automatically during write
        }));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<VlanHeader> {},
        }
    }

    /// Adds two vlan tagging header with the given vlan identifiers (also known as double vlan tagging).
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::{PacketBuilder, SingleVlanHeader, VlanHeader};
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],     //source mac
    ///               [7,8,9,10,11,12]) //destination mac
    ///     .double_vlan(0x123.try_into().unwrap(), // outer vlan identifier
    ///                  0x234.try_into().unwrap()) // inner vlan identifier
    ///     .ipv4([192,168,1,1], //source ip
    ///           [192,168,1,2], //destination ip
    ///           20)            //time to life
    ///     .udp(21,    //source port
    ///          1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn double_vlan(
        mut self,
        outer_vlan_identifier: VlanId,
        inner_vlan_identifier: VlanId,
    ) -> PacketBuilderStep<VlanHeader> {
        self.state.vlan_header = Some(VlanHeader::Double(DoubleVlanHeader {
            outer: SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: outer_vlan_identifier,
                ether_type: EtherType(0), //will be set automatically during write
            },
            inner: SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: inner_vlan_identifier,
                ether_type: EtherType(0), //will be set automatically during write
            },
        }));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<VlanHeader> {},
        }
    }

    /// Adds an ARP packet.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// use etherparse::*;
    ///
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],    // source mac
    ///               [7,8,9,10,11,12]) // destination mac
    ///     .arp(ArpPacket::new(
    ///         ArpHardwareId::ETHERNET,
    ///         EtherType::IPV4,
    ///         ArpOperation::REQUEST,
    ///         &[1,2,3,4,5,6], // sender_hw_addr
    ///         &[7,6,8,9],     // sender_protocol_addr
    ///         &[10,11,12,14,15,16], // target_hw_addr
    ///         &[17,18,19,20]        // target_protocol_addr
    ///     ).unwrap());
    ///
    /// // get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(builder.size());
    ///
    /// // serialize
    /// builder.write(&mut result).unwrap();
    /// ```
    pub fn arp(mut self, arp_packet: ArpPacket) -> PacketBuilderStep<ArpPacket> {
        self.state.net_header = Some(NetHeaders::Arp(arp_packet));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<ArpPacket> {},
        }
    }
}

impl PacketBuilderStep<LinuxSllHeader> {
    /// Add an ip header (length, protocol/next_header & checksum fields will be overwritten based on the rest of the packet).
    ///
    /// # Example IPv4
    /// ```
    /// # use etherparse::*;
    /// #
    /// let builder = PacketBuilder::
    ///     linux_sll(LinuxSllPacketType::OTHERHOST, //packet type
    ///               6, //sender address valid length
    ///               [1,2,3,4,5,6,0,0]) //sender address with padding
    ///    //payload_len, protocol & checksum will be replaced during write
    ///    .ip(IpHeaders::Ipv4(
    ///         Ipv4Header::new(
    ///             0, //payload_len will be replaced during write
    ///             12, //time_to_live
    ///             ip_number::UDP, //will be replaced during write
    ///             [0,1,2,3], //source
    ///             [4,5,6,7] //destination
    ///         ).unwrap(),
    ///         Default::default() // IPv4 extension headers (default is none)
    ///     ));
    /// ```
    ///
    /// # Example IPv6
    /// ```
    /// # use etherparse::*;
    /// #
    /// let builder = PacketBuilder::
    ///     linux_sll(LinuxSllPacketType::OTHERHOST, //packet type
    ///               6, //sender address valid length
    ///               [1,2,3,4,5,6,0,0]) //sender address with padding
    ///    .ip(IpHeaders::Ipv6(
    ///         Ipv6Header{
    ///             traffic_class: 0,
    ///             flow_label: 0.try_into().unwrap(),
    ///             hop_limit: 4,
    ///             source: [0;16],
    ///             destination: [0;16],
    ///             // payload_length & next_header will be replaced during write
    ///             ..Default::default()
    ///         },
    ///         Default::default() // IPv6 extension headers (default is none)
    ///     ));
    /// ```
    pub fn ip(self, ip_header: IpHeaders) -> PacketBuilderStep<IpHeaders> {
        //use the method from the Ethernet2Header implementation
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Ethernet2Header> {},
        }
        .ip(ip_header)
    }

    /// Add an IPv6 header
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::{PacketBuilder, LinuxSllPacketType, ArpHardwareId, LinuxSllProtocolType, EtherType};
    /// #
    /// let builder = PacketBuilder::
    ///     linux_sll(LinuxSllPacketType::OTHERHOST, //packet type
    ///               6, //sender address valid length
    ///               [1,2,3,4,5,6,0,0]) //sender address with padding
    ///     .ipv6(
    ///         //source
    ///         [11,12,13,14,15,16,17,18,19,10,21,22,23,24,25,26],
    ///         //destination
    ///         [31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46],
    ///         //hop_limit
    ///         47)
    ///     .udp(21,    //source port
    ///          1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn ipv6(
        self,
        source: [u8; 16],
        destination: [u8; 16],
        hop_limit: u8,
    ) -> PacketBuilderStep<IpHeaders> {
        //use the method from the Ethernet2Header implementation
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Ethernet2Header> {},
        }
        .ipv6(source, destination, hop_limit)
    }

    /// Add an IPv4 header
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::{PacketBuilder, LinuxSllPacketType, ArpHardwareId, LinuxSllProtocolType, EtherType};
    /// #
    /// let builder = PacketBuilder::
    ///     linux_sll(LinuxSllPacketType::OTHERHOST, //packet type
    ///               6, //sender address valid length
    ///               [1,2,3,4,5,6,0,0]) //sender address with padding
    ///     .ipv4([192,168,1,1], //source ip
    ///           [192,168,1,2], //destination ip
    ///           20)            //time to life
    ///     .udp(21,    //source port
    ///          1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn ipv4(
        self,
        source: [u8; 4],
        destination: [u8; 4],
        time_to_live: u8,
    ) -> PacketBuilderStep<IpHeaders> {
        //use the method from the Ethernet2Header implementation
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Ethernet2Header> {},
        }
        .ipv4(source, destination, time_to_live)
    }

    /// Adds an ARP packet.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// use etherparse::*;
    ///
    /// let builder = PacketBuilder::
    ///     linux_sll(LinuxSllPacketType::OTHERHOST, //packet type
    ///               6, //sender address valid length
    ///               [1,2,3,4,5,6,0,0]) //sender address with padding
    ///     .arp(ArpPacket::new(
    ///         ArpHardwareId::ETHERNET,
    ///         EtherType::IPV4,
    ///         ArpOperation::REQUEST,
    ///         &[1,2,3,4,5,6], // sender_hw_addr
    ///         &[7,6,8,9],     // sender_protocol_addr
    ///         &[10,11,12,14,15,16], // target_hw_addr
    ///         &[17,18,19,20]        // target_protocol_addr
    ///     ).unwrap());
    ///
    /// // get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(builder.size());
    ///
    /// // serialize
    /// builder.write(&mut result).unwrap();
    /// ```
    pub fn arp(mut self, arp_packet: ArpPacket) -> PacketBuilderStep<ArpPacket> {
        self.state.net_header = Some(NetHeaders::Arp(arp_packet));
        // return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<ArpPacket> {},
        }
    }
}

impl PacketBuilderStep<VlanHeader> {
    ///Add an ip header (length, protocol/next_header & checksum fields will be overwritten based on the rest of the packet).
    ///
    /// # Example IPv4
    /// ```
    /// # use etherparse::*;
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],
    ///               [7,8,9,10,11,12])
    ///    .single_vlan(0x132.try_into().unwrap())
    ///    //payload_len, protocol & checksum will be replaced during write
    ///    .ip(IpHeaders::Ipv4(
    ///         Ipv4Header::new(
    ///             0, //payload_len will be replaced during write
    ///             12, //time_to_live
    ///             ip_number::UDP, //will be replaced during write
    ///             [0,1,2,3], //source
    ///             [4,5,6,7] //destination
    ///         ).unwrap(),
    ///         Default::default() // IPv4 extension headers (default is none)
    ///     ));
    /// ```
    ///
    /// # Example IPv6
    /// ```
    /// # use etherparse::*;
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],
    ///               [7,8,9,10,11,12])
    ///    .single_vlan(0x132.try_into().unwrap())
    ///    .ip(IpHeaders::Ipv6(
    ///         Ipv6Header{
    ///             traffic_class: 0,
    ///             flow_label: 0.try_into().unwrap(),
    ///             hop_limit: 4,
    ///             source: [0;16],
    ///             destination: [0;16],
    ///             // payload_length & next_header will be replaced during write
    ///             ..Default::default()
    ///         },
    ///         Default::default() // IPv6 extension headers (default is none)
    ///     ));
    /// ```
    pub fn ip(self, ip_header: IpHeaders) -> PacketBuilderStep<IpHeaders> {
        //use the method from the Ethernet2Header implementation
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Ethernet2Header> {},
        }
        .ip(ip_header)
    }

    /// Add an IPv6 header
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::{PacketBuilder, SingleVlanHeader, VlanHeader};
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],     //source mac
    ///               [7,8,9,10,11,12]) //destination mac
    ///     .single_vlan(0x123.try_into().unwrap()) // vlan identifier
    ///     .ipv6(
    ///         //source
    ///         [11,12,13,14,15,16,17,18,19,10,21,22,23,24,25,26],
    ///         //destination
    ///         [31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46],
    ///         //hop_limit
    ///         47)
    ///     .udp(21,    //source port
    ///          1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn ipv6(
        self,
        source: [u8; 16],
        destination: [u8; 16],
        hop_limit: u8,
    ) -> PacketBuilderStep<IpHeaders> {
        //use the method from the Ethernet2Header implementation
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Ethernet2Header> {},
        }
        .ipv6(source, destination, hop_limit)
    }

    /// Add an IPv4 header
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::{PacketBuilder, SingleVlanHeader, VlanHeader};
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],     //source mac
    ///               [7,8,9,10,11,12]) //destination mac
    ///     .single_vlan(0x123.try_into().unwrap()) // vlan identifier
    ///     .ipv4([192,168,1,1], //source ip
    ///           [192,168,1,2], //destination ip
    ///           20)            //time to life
    ///     .udp(21,    //source port
    ///          1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn ipv4(
        self,
        source: [u8; 4],
        destination: [u8; 4],
        time_to_live: u8,
    ) -> PacketBuilderStep<IpHeaders> {
        //use the method from the Ethernet2Header implementation
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Ethernet2Header> {},
        }
        .ipv4(source, destination, time_to_live)
    }

    /// Adds an ARP packet.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// use etherparse::*;
    ///
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],    // source mac
    ///               [7,8,9,10,11,12]) // destination mac
    ///     .single_vlan(0x123.try_into().unwrap()) // vlan identifier
    ///     .arp(ArpPacket::new(
    ///         ArpHardwareId::ETHERNET,
    ///         EtherType::IPV4,
    ///         ArpOperation::REQUEST,
    ///         &[1,2,3,4,5,6], // sender_hw_addr
    ///         &[7,6,8,9],     // sender_protocol_addr
    ///         &[10,11,12,14,15,16], // target_hw_addr
    ///         &[17,18,19,20]        // target_protocol_addr
    ///     ).unwrap());
    ///
    /// // get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(builder.size());
    ///
    /// // serialize
    /// builder.write(&mut result).unwrap();
    /// ```
    pub fn arp(mut self, arp_packet: ArpPacket) -> PacketBuilderStep<ArpPacket> {
        self.state.net_header = Some(NetHeaders::Arp(arp_packet));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<ArpPacket> {},
        }
    }
}

impl PacketBuilderStep<IpHeaders> {
    /// Adds an ICMPv4 header of the given [`Icmpv4Type`] to the packet.
    ///
    /// If an ICMPv4 header gets added the payload used during the builders `write`
    /// call contains the bytes after the header and has different meanings
    /// and contents based on the type. Usually all statically sized values
    /// known based on the ICMPv4 type & code are part of the header and the
    /// payload is used to store contains the dynamic parts of the ICMPv4 packet.
    ///
    /// Check [`Icmpv4Type`] for a documentation which values are part of the
    /// header and what is stored as part of the payload.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::{PacketBuilder, Icmpv4Type, icmpv4};
    /// #
    /// let builder = PacketBuilder::
    ///    ipv4([192,168,1,1],  //source ip
    ///          [192,168,1,2], //destination ip
    ///          20)            //time to life
    ///    .icmpv4(
    ///         Icmpv4Type::TimeExceeded(
    ///             icmpv4::TimeExceededCode::TtlExceededInTransit
    ///         )
    ///     );
    ///
    /// // what is part of the payload depends on the Icmpv4Type
    /// //
    /// // In case of `Icmpv4Type::TimeExceeded` the "internet header
    /// // + 64 bits of the original data datagram" should be given as
    /// // the payload
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn icmpv4(mut self, icmp_type: Icmpv4Type) -> PacketBuilderStep<Icmpv4Header> {
        self.state.transport_header = Some(TransportHeader::Icmpv4(Icmpv4Header {
            icmp_type,
            checksum: 0, // calculated later
        }));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Icmpv4Header> {},
        }
    }

    /// Adds an ICMPv4 header based on raw numbers.
    ///
    /// This can be useful when trying to build an ICMPv4 packet
    /// which is not fully supported by etherparse and is the equivalent
    /// of using [`Icmpv4Type::Unknown`] together with
    /// [`PacketBuilderStep<IpHeaders>::icmpv4`].
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///    ipv4([192,168,1,1],  //source ip
    ///          [192,168,1,2], //destination ip
    ///          20)            //time to life
    ///    .icmpv4_raw(
    ///         253, // ICMPv4 type (e.g. 253 is RFC3692-style Experiment 1)
    ///         0, // ICMPv4 code
    ///         [1,2,3,4]  // bytes 5-8 in the ICMPv4 header
    ///     );
    ///
    /// // the payload is written after the 8 byte raw ICMPv4 header
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// // get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// // serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn icmpv4_raw(
        mut self,
        type_u8: u8,
        code_u8: u8,
        bytes5to8: [u8; 4],
    ) -> PacketBuilderStep<Icmpv4Header> {
        let icmp_type = Icmpv4Type::Unknown {
            type_u8,
            code_u8,
            bytes5to8,
        };
        self.state.transport_header = Some(TransportHeader::Icmpv4(Icmpv4Header {
            icmp_type,
            checksum: 0, // calculated later
        }));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Icmpv4Header> {},
        }
    }

    /// Adds an ICMPv4 echo request packet.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///    ipv4([192,168,1,1],  //source ip
    ///          [192,168,1,2], //destination ip
    ///          20)            //time to life
    ///    .icmpv4_echo_request(
    ///         123, // identifier
    ///         456, // sequence number
    ///     );
    ///
    /// // payload of the echo request
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// // get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// // serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn icmpv4_echo_request(mut self, id: u16, seq: u16) -> PacketBuilderStep<Icmpv4Header> {
        let echo_header = IcmpEchoHeader { id, seq };
        let icmpv4_echo = Icmpv4Header::new(Icmpv4Type::EchoRequest(echo_header));
        self.state.transport_header = Some(TransportHeader::Icmpv4(icmpv4_echo));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Icmpv4Header> {},
        }
    }

    /// Adds an ICMPv4 echo reply packet.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///    ipv4([192,168,1,1],  //source ip
    ///          [192,168,1,2], //destination ip
    ///          20)            //time to life
    ///    .icmpv4_echo_reply(
    ///         123, // identifier
    ///         456, // sequence number
    ///     );
    ///
    /// // payload of the echo reply
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// // get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// // serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn icmpv4_echo_reply(mut self, id: u16, seq: u16) -> PacketBuilderStep<Icmpv4Header> {
        let echo_header = IcmpEchoHeader { id, seq };
        let icmpv4_echo = Icmpv4Header::new(Icmpv4Type::EchoReply(echo_header));
        self.state.transport_header = Some(TransportHeader::Icmpv4(icmpv4_echo));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Icmpv4Header> {},
        }
    }

    /// Adds an ICMPv6 header of the given [`Icmpv6Type`] to the packet.
    ///
    /// If an ICMPv6 header gets added the payload used during the builders `write`
    /// call contains the bytes after the header and has different meanings
    /// and contents based on the type. Usually all statically sized values
    /// known based on the ICMPv6 type & code are part of the header and the
    /// payload is used to store contains the dynamic parts of the ICMPv6 packet.
    ///
    /// Check [`Icmpv6Type`] for a documentation which values are part of the
    /// header and what is stored as part of the payload.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::{PacketBuilder, Icmpv6Type, icmpv6};
    /// #
    /// let builder = PacketBuilder::
    ///     ipv6(
    ///         //source
    ///         [11,12,13,14,15,16,17,18,19,10,21,22,23,24,25,26],
    ///         //destination
    ///         [31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46],
    ///         //hop_limit
    ///         47)
    ///    .icmpv6(
    ///         Icmpv6Type::TimeExceeded(
    ///             icmpv6::TimeExceededCode::HopLimitExceeded
    ///         )
    ///     );
    ///
    /// // what is part of the payload depends on the Icmpv6Type
    /// //
    /// // In case of `Icmpv6Type::TimeExceeded` "As much of invoking packet
    /// // as possible without the ICMPv6 packet exceeding the minimum IPv6 MTU"
    /// // should be given as the payload.
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn icmpv6(mut self, icmp_type: Icmpv6Type) -> PacketBuilderStep<Icmpv6Header> {
        self.state.transport_header = Some(TransportHeader::Icmpv6(Icmpv6Header {
            icmp_type,
            checksum: 0, // calculated later
        }));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Icmpv6Header> {},
        }
    }

    /// Adds an ICMPv6 header based on raw values.
    ///
    /// This can be useful when trying to build an ICMPv6 packet
    /// which is not fully supported by etherparse and is the equivalent
    /// of using [`Icmpv6Type::Unknown`] together with
    /// [`PacketBuilderStep<IpHeaders>::icmpv6`].
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///     ipv6(
    ///         //source
    ///         [11,12,13,14,15,16,17,18,19,10,21,22,23,24,25,26],
    ///         //destination
    ///         [31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46],
    ///         //hop_limit
    ///         47)
    ///    .icmpv4_raw(
    ///         200, // ICMPv6 type (e.g. 200 is for "private experimentation")
    ///         0, // ICMPv6 code
    ///         [1,2,3,4]  // bytes 5-8 in the ICMPv6 header
    ///     );
    ///
    /// // the payload is written after the 8 byte raw ICMPv6 header
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn icmpv6_raw(
        mut self,
        type_u8: u8,
        code_u8: u8,
        bytes5to8: [u8; 4],
    ) -> PacketBuilderStep<Icmpv6Header> {
        let icmp_type = Icmpv6Type::Unknown {
            type_u8,
            code_u8,
            bytes5to8,
        };
        self.state.transport_header = Some(TransportHeader::Icmpv6(Icmpv6Header {
            icmp_type,
            checksum: 0, // calculated later
        }));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Icmpv6Header> {},
        }
    }

    /// Adds an ICMPv6 echo reply packet.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///     ipv6(
    ///         //source
    ///         [11,12,13,14,15,16,17,18,19,10,21,22,23,24,25,26],
    ///         //destination
    ///         [31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46],
    ///         //hop_limit
    ///         47)
    ///    .icmpv6_echo_request(
    ///         123, // identifier
    ///         456, // sequence number
    ///     );
    ///
    /// // payload of the echo request
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn icmpv6_echo_request(mut self, id: u16, seq: u16) -> PacketBuilderStep<Icmpv6Header> {
        let echo_header = IcmpEchoHeader { id, seq };
        let icmpv6_echo = Icmpv6Header::new(Icmpv6Type::EchoRequest(echo_header));
        self.state.transport_header = Some(TransportHeader::Icmpv6(icmpv6_echo));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Icmpv6Header> {},
        }
    }

    /// Adds an ICMPv6 echo request packet.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///     ipv6(
    ///         //source
    ///         [11,12,13,14,15,16,17,18,19,10,21,22,23,24,25,26],
    ///         //destination
    ///         [31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46],
    ///         //hop_limit
    ///         47)
    ///    .icmpv6_echo_reply(
    ///         123, // identifier
    ///         456, // sequence number
    ///     );
    ///
    /// // payload of the echo reply
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn icmpv6_echo_reply(mut self, id: u16, seq: u16) -> PacketBuilderStep<Icmpv6Header> {
        let echo_header = IcmpEchoHeader { seq, id };
        let icmpv6_echo = Icmpv6Header::new(Icmpv6Type::EchoReply(echo_header));
        self.state.transport_header = Some(TransportHeader::Icmpv6(icmpv6_echo));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<Icmpv6Header> {},
        }
    }

    /// Adds an UDP header.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],     //source mac
    ///               [7,8,9,10,11,12]) //destination mac
    ///    .ipv4([192,168,1,1], //source ip
    ///          [192,168,1,2], //destination ip
    ///          20)            //time to life
    ///    .udp(21,    //source port
    ///         1234); //destination port
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn udp(mut self, source_port: u16, destination_port: u16) -> PacketBuilderStep<UdpHeader> {
        self.state.transport_header = Some(TransportHeader::Udp(UdpHeader {
            source_port,
            destination_port,
            length: 0,   //calculated later
            checksum: 0, //calculated later
        }));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<UdpHeader> {},
        }
    }

    /// Adds a simple TCP header.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// #
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],     // source mac
    ///               [7,8,9,10,11,12]) // destination mac
    ///    .ipv4([192,168,1,1], // source ip
    ///          [192,168,1,2], // destination ip
    ///          20)            // time to life
    ///    .tcp(21,    // source port
    ///         12,    // destination port
    ///         12345, // sequence number
    ///         4000); // window size
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn tcp(
        mut self,
        source_port: u16,
        destination_port: u16,
        sequence_number: u32,
        window_size: u16,
    ) -> PacketBuilderStep<TcpHeader> {
        self.state.transport_header = Some(TransportHeader::Tcp(TcpHeader::new(
            source_port,
            destination_port,
            sequence_number,
            window_size,
        )));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<TcpHeader> {},
        }
    }

    /// Adds a more complicated TCP header.
    ///
    /// # Example
    ///
    /// Basic usage:
    ///
    /// ```
    /// # use etherparse::PacketBuilder;
    /// use etherparse::TcpHeader;
    ///
    /// let mut tcp_header = TcpHeader::new(
    ///     21,     // source port
    ///     12,     // destination port
    ///     12345,  // sequence number
    ///     4000,   // window size
    /// );
    /// tcp_header.psh = true;
    /// tcp_header.ack = true;
    /// tcp_header.acknowledgment_number = 1;
    ///
    /// let builder = PacketBuilder::
    ///     ethernet2([1,2,3,4,5,6],     // source mac
    ///               [7,8,9,10,11,12]) // destination mac
    ///    .ipv4([192,168,1,1], // source ip
    ///          [192,168,1,2], // destination ip
    ///          20)            // time to life
    ///    .tcp_header(tcp_header);
    ///
    /// //payload of the udp packet
    /// let payload = [1,2,3,4,5,6,7,8];
    ///
    /// //get some memory to store the result
    /// let mut result = Vec::<u8>::with_capacity(
    ///                     builder.size(payload.len()));
    ///
    /// //serialize
    /// builder.write(&mut result, &payload).unwrap();
    /// ```
    pub fn tcp_header(mut self, tcp_header: TcpHeader) -> PacketBuilderStep<TcpHeader> {
        self.state.transport_header = Some(TransportHeader::Tcp(tcp_header));
        //return for next step
        PacketBuilderStep {
            state: self.state,
            _marker: marker::PhantomData::<TcpHeader> {},
        }
    }

    /// Write all the headers and the payload with the given ip number.
    ///
    /// `last_next_header_ip_number` will be set in the last extension header
    /// or if no extension header exists the ip header as the "next header" or
    /// "protocol number".
    #[cfg(feature = "std")]
    pub fn write<T: std::io::Write + Sized>(
        mut self,
        writer: &mut T,
        last_next_header_ip_number: IpNumber,
        payload: &[u8],
    ) -> Result<(), BuildWriteError> {
        match &mut (self.state.net_header) {
            Some(NetHeaders::Ipv4(ref mut ip, ref mut exts)) => {
                ip.protocol = exts.set_next_headers(last_next_header_ip_number);
            }
            Some(NetHeaders::Ipv6(ref mut ip, ref mut exts)) => {
                ip.next_header = exts.set_next_headers(last_next_header_ip_number);
            }
            _ => {}
        }
        final_write_with_net::<_, _, BuildWriteError>(self, &mut IoWriter(writer), payload)
    }

    /// Write all the headers and the payload to a [`Vec<u8>`].
    #[cfg(feature = "alloc")]
    #[cfg_attr(docsrs, doc(cfg(feature = "alloc")))]
    pub fn write_to_vec(
        mut self,
        buffer: &mut Vec<u8>,
        last_next_header_ip_number: IpNumber,
        payload: &[u8],
    ) -> Result<(), BuildVecWriteError> {
        match &mut (self.state.net_header) {
            Some(NetHeaders::Ipv4(ref mut ip, ref mut exts)) => {
                ip.protocol = exts.set_next_headers(last_next_header_ip_number);
            }
            Some(NetHeaders::Ipv6(ref mut ip, ref mut exts)) => {
                ip.next_header = exts.set_next_headers(last_next_header_ip_number);
            }
            _ => {}
        }
        final_write_with_net::<_, _, BuildVecWriteError>(self, &mut VecWriter(buffer), payload)
    }

    /// Write all the headers and the payload to a byte slice.
    ///
    /// Returns the number of bytes written.
    pub fn write_to_slice(
        mut self,
        buffer: &mut [u8],
        last_next_header_ip_number: IpNumber,
        payload: &[u8],
    ) -> Result<usize, BuildSliceWriteError> {
        match &mut (self.state.net_header) {
            Some(NetHeaders::Ipv4(ref mut ip, ref mut exts)) => {
                ip.protocol = exts.set_next_headers(last_next_header_ip_number);
            }
            Some(NetHeaders::Ipv6(ref mut ip, ref mut exts)) => {
                ip.next_header = exts.set_next_headers(last_next_header_ip_number);
            }
            _ => {}
        }

        final_write_to_slice(self, buffer, payload)
    }

    ///Returns the size of the packet when it is serialized
    pub fn size(&self, payload_size: usize) -> usize {
        final_size(self, payload_size)
    }
}

impl PacketBuilderStep<Icmpv4Header> {
    /// Write all the headers and the payload.
    #[cfg(feature = "std")]
    pub fn write<T: std::io::Write + Sized>(
        self,
        writer: &mut T,
        payload: &[u8],
    ) -> Result<(), BuildWriteError> {
        final_write_with_net::<_, _, BuildWriteError>(self, &mut IoWriter(writer), payload)
    }

    /// Write all the headers and the payload to a [`Vec<u8>`].
    #[cfg(feature = "alloc")]
    #[cfg_attr(docsrs, doc(cfg(feature = "alloc")))]
    pub fn write_to_vec(
        self,
        buffer: &mut Vec<u8>,
        payload: &[u8],
    ) -> Result<(), BuildVecWriteError> {
        final_write_with_net::<_, _, BuildVecWriteError>(self, &mut VecWriter(buffer), payload)
    }

    /// Write all the headers and the payload to a byte slice.
    ///
    /// Returns the number of bytes written.
    pub fn write_to_slice(
        self,
        buffer: &mut [u8],
        payload: &[u8],
    ) -> Result<usize, BuildSliceWriteError> {
        final_write_to_slice(self, buffer, payload)
    }

    /// Returns the size of the packet when it is serialized
    pub fn size(&self, payload_size: usize) -> usize {
        final_size(self, payload_size)
    }
}

impl PacketBuilderStep<Icmpv6Header> {
    ///Write all the headers and the payload.
    #[cfg(feature = "std")]
    pub fn write<T: std::io::Write + Sized>(
        self,
        writer: &mut T,
        payload: &[u8],
    ) -> Result<(), BuildWriteError> {
        final_write_with_net::<_, _, BuildWriteError>(self, &mut IoWriter(writer), payload)
    }

    /// Write all the headers and the payload to a [`Vec<u8>`].
    #[cfg(feature = "alloc")]
    #[cfg_attr(docsrs, doc(cfg(feature = "alloc")))]
    pub fn write_to_vec(
        self,
        buffer: &mut Vec<u8>,
        payload: &[u8],
    ) -> Result<(), BuildVecWriteError> {
        final_write_with_net::<_, _, BuildVecWriteError>(self, &mut VecWriter(buffer), payload)
    }

    /// Write all the headers and the payload to a byte slice.
    ///
    /// Returns the number of bytes written.
    pub fn write_to_slice(
        self,
        buffer: &mut [u8],
        payload: &[u8],
    ) -> Result<usize, BuildSliceWriteError> {
        final_write_to_slice(self, buffer, payload)
    }

    ///Returns the size of the packet when it is serialized
    pub fn size(&self, payload_size: usize) -> usize {
        final_size(self, payload_size)
    }
}

impl PacketBuilderStep<UdpHeader> {
    ///Write all the headers and the payload.
    #[cfg(feature = "std")]
    pub fn write<T: std::io::Write + Sized>(
        self,
        writer: &mut T,
        payload: &[u8],
    ) -> Result<(), BuildWriteError> {
        final_write_with_net::<_, _, BuildWriteError>(self, &mut IoWriter(writer), payload)
    }

    /// Write all the headers and the payload to a [`Vec<u8>`].
    #[cfg(feature = "alloc")]
    #[cfg_attr(docsrs, doc(cfg(feature = "alloc")))]
    pub fn write_to_vec(
        self,
        buffer: &mut Vec<u8>,
        payload: &[u8],
    ) -> Result<(), BuildVecWriteError> {
        final_write_with_net::<_, _, BuildVecWriteError>(self, &mut VecWriter(buffer), payload)
    }

    /// Write all the headers and the payload to a byte slice.
    ///
    /// Returns the number of bytes written.
    pub fn write_to_slice(
        self,
        buffer: &mut [u8],
        payload: &[u8],
    ) -> Result<usize, BuildSliceWriteError> {
        final_write_to_slice(self, buffer, payload)
    }

    ///Returns the size of the packet when it is serialized
    pub fn size(&self, payload_size: usize) -> usize {
        final_size(self, payload_size)
    }
}

impl PacketBuilderStep<TcpHeader> {
    ///Set ns flag (ECN-nonce - concealment protection; experimental: see RFC 3540)
    pub fn ns(mut self) -> PacketBuilderStep<TcpHeader> {
        self.state
            .transport_header
            .as_mut()
            .unwrap()
            .mut_tcp()
            .unwrap()
            .ns = true;
        self
    }
    ///Set fin flag (No more data from sender)
    pub fn fin(mut self) -> PacketBuilderStep<TcpHeader> {
        self.state
            .transport_header
            .as_mut()
            .unwrap()
            .mut_tcp()
            .unwrap()
            .fin = true;
        self
    }
    ///Set the syn flag (synchronize sequence numbers)
    pub fn syn(mut self) -> PacketBuilderStep<TcpHeader> {
        self.state
            .transport_header
            .as_mut()
            .unwrap()
            .mut_tcp()
            .unwrap()
            .syn = true;
        self
    }
    ///Sets the rst flag (reset the connection)
    pub fn rst(mut self) -> PacketBuilderStep<TcpHeader> {
        self.state
            .transport_header
            .as_mut()
            .unwrap()
            .mut_tcp()
            .unwrap()
            .rst = true;
        self
    }
    ///Sets the psh flag (push function)
    pub fn psh(mut self) -> PacketBuilderStep<TcpHeader> {
        self.state
            .transport_header
            .as_mut()
            .unwrap()
            .mut_tcp()
            .unwrap()
            .psh = true;
        self
    }
    ///Sets the ack flag and the acknowledgment_number.
    pub fn ack(mut self, acknowledgment_number: u32) -> PacketBuilderStep<TcpHeader> {
        {
            let header = self
                .state
                .transport_header
                .as_mut()
                .unwrap()
                .mut_tcp()
                .unwrap();
            header.ack = true;
            header.acknowledgment_number = acknowledgment_number;
        }
        self
    }
    ///Set the urg flag & the urgent pointer field.
    ///
    ///The urgent pointer points to the sequence number of the octet following
    ///the urgent data.
    pub fn urg(mut self, urgent_pointer: u16) -> PacketBuilderStep<TcpHeader> {
        {
            let header = self
                .state
                .transport_header
                .as_mut()
                .unwrap()
                .mut_tcp()
                .unwrap();
            header.urg = true;
            header.urgent_pointer = urgent_pointer;
        }
        self
    }
    ///Sets ece flag (ECN-Echo, RFC 3168)
    pub fn ece(mut self) -> PacketBuilderStep<TcpHeader> {
        self.state
            .transport_header
            .as_mut()
            .unwrap()
            .mut_tcp()
            .unwrap()
            .ece = true;
        self
    }

    ///Set cwr flag (Congestion Window Reduced)
    ///
    ///This flag is set by the sending host to indicate that it received a TCP segment with the ECE flag set and had responded in congestion control mechanism (added to header by RFC 3168).
    pub fn cwr(mut self) -> PacketBuilderStep<TcpHeader> {
        self.state
            .transport_header
            .as_mut()
            .unwrap()
            .mut_tcp()
            .unwrap()
            .cwr = true;
        self
    }

    ///Set the tcp options of the header.
    pub fn options(
        mut self,
        options: &[TcpOptionElement],
    ) -> Result<PacketBuilderStep<TcpHeader>, TcpOptionWriteError> {
        self.state
            .transport_header
            .as_mut()
            .unwrap()
            .mut_tcp()
            .unwrap()
            .set_options(options)?;
        Ok(self)
    }

    ///Set the tcp options of the header (setting the bytes directly).
    pub fn options_raw(
        mut self,
        options: &[u8],
    ) -> Result<PacketBuilderStep<TcpHeader>, TcpOptionWriteError> {
        self.state
            .transport_header
            .as_mut()
            .unwrap()
            .mut_tcp()
            .unwrap()
            .set_options_raw(options)?;
        Ok(self)
    }

    ///Write all the headers and the payload.
    #[cfg(feature = "std")]
    pub fn write<T: std::io::Write + Sized>(
        self,
        writer: &mut T,
        payload: &[u8],
    ) -> Result<(), BuildWriteError> {
        final_write_with_net::<_, _, BuildWriteError>(self, &mut IoWriter(writer), payload)
    }

    /// Write all the headers and the payload to a [`Vec<u8>`].
    #[cfg(feature = "alloc")]
    #[cfg_attr(docsrs, doc(cfg(feature = "alloc")))]
    pub fn write_to_vec(
        self,
        buffer: &mut Vec<u8>,
        payload: &[u8],
    ) -> Result<(), BuildVecWriteError> {
        final_write_with_net::<_, _, BuildVecWriteError>(self, &mut VecWriter(buffer), payload)
    }

    /// Write all the headers and the payload to a byte slice.
    ///
    /// Returns the number of bytes written.
    pub fn write_to_slice(
        self,
        buffer: &mut [u8],
        payload: &[u8],
    ) -> Result<usize, BuildSliceWriteError> {
        final_write_to_slice(self, buffer, payload)
    }

    ///Returns the size of the packet when it is serialized
    pub fn size(&self, payload_size: usize) -> usize {
        final_size(self, payload_size)
    }
}

impl PacketBuilderStep<ArpPacket> {
    #[cfg(feature = "std")]
    pub fn write<T: std::io::Write + Sized>(self, writer: &mut T) -> Result<(), BuildWriteError> {
        final_write_with_net::<_, _, BuildWriteError>(self, &mut IoWriter(writer), &[])?;
        Ok(())
    }

    /// Write all the headers to a [`Vec<u8>`].
    #[cfg(feature = "alloc")]
    #[cfg_attr(docsrs, doc(cfg(feature = "alloc")))]
    pub fn write_to_vec(self, buffer: &mut Vec<u8>) -> Result<(), BuildVecWriteError> {
        final_write_with_net::<_, _, BuildVecWriteError>(self, &mut VecWriter(buffer), &[])?;
        Ok(())
    }

    /// Write all the headers to a byte slice.
    ///
    /// Returns the number of bytes written.
    pub fn write_to_slice(self, buffer: &mut [u8]) -> Result<usize, BuildSliceWriteError> {
        final_write_to_slice(self, buffer, &[])
    }

    pub fn size(&self) -> usize {
        final_size(self, 0)
    }
}

/// Write all the headers and the payload.
fn final_write_with_net<W, B, E>(
    builder: PacketBuilderStep<B>,
    writer: &mut W,
    payload: &[u8],
) -> Result<(), E>
where
    W: CoreWrite + Sized,
    E: From<W::Error>
        + From<crate::WriteError<W::Error, err::ipv4_exts::ExtsWalkError>>
        + From<crate::WriteError<W::Error, err::ipv6_exts::ExtsWalkError>>
        + From<err::ValueTooBigError<usize>>
        + From<err::packet::TransportChecksumError>,
{
    use NetHeaders::*;

    // unpack builder (makes things easier with the borrow checker)
    let link = builder.state.link_header;
    let vlan = builder.state.vlan_header;
    let net = builder.state.net_header;
    let mut transport = builder.state.transport_header;

    // determine
    let net_ether_type = match &net {
        Some(Ipv4(_, _)) => ether_type::IPV4,
        Some(Ipv6(_, _)) => ether_type::IPV6,
        Some(Arp(_)) => ether_type::ARP,
        None => unreachable!(),
    };

    // link header
    if let Some(link) = link {
        match link {
            LinkHeader::Ethernet2(mut eth) => {
                eth.ether_type = {
                    use crate::VlanHeader::*;
                    //determine the ether type depending on if there is a vlan tagging header
                    match &vlan {
                        Some(Single(_)) => ether_type::VLAN_TAGGED_FRAME,
                        Some(Double(_)) => ether_type::PROVIDER_BRIDGING,
                        //if no vlan header exists, the id is purely defined by the ip type
                        None => net_ether_type,
                    }
                };
                writer.write_all(&eth.to_bytes()).map_err(E::from)?;
            }
            LinkHeader::LinuxSll(mut linux_sll) => {
                // Assumes that next layers are ether based. If more types of
                // layers are supported, this should be updated
                debug_assert_eq!(linux_sll.arp_hrd_type, ArpHardwareId::ETHERNET);

                linux_sll.protocol_type.change_value(net_ether_type.into());
                writer.write_all(&linux_sll.to_bytes()).map_err(E::from)?;
            }
        }
    }

    // write the vlan header if it exists
    use crate::VlanHeader::*;
    match vlan {
        Some(Single(mut value)) => {
            //set ether types
            value.ether_type = net_ether_type;
            //serialize
            writer.write_all(&value.to_bytes()).map_err(E::from)?;
        }
        Some(Double(mut value)) => {
            //set ether types
            value.outer.ether_type = ether_type::VLAN_TAGGED_FRAME;
            value.inner.ether_type = net_ether_type;
            //serialize
            writer.write_all(&value.outer.to_bytes()).map_err(E::from)?;
            writer.write_all(&value.inner.to_bytes()).map_err(E::from)?;
        }
        None => {}
    }

    // set transport header length (needs to be done here
    // so following steps can correctly calculate the checksum)
    use TransportHeader::*;
    match &mut transport {
        Some(Udp(ref mut udp)) => {
            udp.length = (UdpHeader::LEN + payload.len()) as u16;
        }
        Some(Tcp(_)) => {}
        Some(Icmpv4(_)) => {}
        Some(Icmpv6(_)) => {}
        None => {}
    }

    // net header
    match net {
        Some(NetHeaders::Ipv4(mut ip, mut ip_exts)) => {
            // set payload length & ip number
            ip.set_payload_len(
                ip_exts.header_len()
                    + transport.as_ref().map(|v| v.header_len()).unwrap_or(0)
                    + payload.len(),
            )
            .map_err(E::from)?;

            if let Some(transport) = &transport {
                ip.protocol = ip_exts.set_next_headers(match &transport {
                    Icmpv4(_) => ip_number::ICMP,
                    Icmpv6(_) => ip_number::IPV6_ICMP,
                    Udp(_) => ip_number::UDP,
                    Tcp(_) => ip_number::TCP,
                });
            }

            // write ip header & extensions
            ip.header_checksum = ip.calc_header_checksum();
            writer.write_all(&ip.to_bytes()).map_err(E::from)?;
            ip_exts
                .write_internal(writer, ip.protocol)
                .map_err(E::from)?;

            // update the transport layer checksum
            if let Some(t) = &mut transport {
                t.update_checksum_ipv4(&ip, payload).map_err(E::from)?;
            }
        }
        Some(NetHeaders::Ipv6(mut ip, mut ip_exts)) => {
            // set payload length & ip number
            ip.set_payload_length(
                ip_exts.header_len()
                    + transport.as_ref().map(|v| v.header_len()).unwrap_or(0)
                    + payload.len(),
            )
            .map_err(E::from)?;

            if let Some(transport) = &transport {
                ip.next_header = ip_exts.set_next_headers(match &transport {
                    Icmpv4(_) => ip_number::ICMP,
                    Icmpv6(_) => ip_number::IPV6_ICMP,
                    Udp(_) => ip_number::UDP,
                    Tcp(_) => ip_number::TCP,
                });
            }

            // write ip header & extensions
            writer.write_all(&ip.to_bytes()).map_err(E::from)?;
            ip_exts
                .write_internal(writer, ip.next_header)
                .map_err(E::from)?;

            // update the transport layer checksum
            if let Some(t) = &mut transport {
                t.update_checksum_ipv6(&ip, payload).map_err(E::from)?;
            }
        }
        Some(NetHeaders::Arp(arp)) => {
            writer.write_all(&arp.to_bytes()).map_err(E::from)?;
        }
        None => {}
    }

    // write transport header
    if let Some(transport) = transport {
        match transport {
            TransportHeader::Icmpv4(value) => {
                writer.write_all(&value.to_bytes()).map_err(E::from)?
            }
            TransportHeader::Icmpv6(value) => {
                writer.write_all(&value.to_bytes()).map_err(E::from)?
            }
            TransportHeader::Udp(value) => writer.write_all(&value.to_bytes()).map_err(E::from)?,
            TransportHeader::Tcp(value) => writer.write_all(&value.to_bytes()).map_err(E::from)?,
        }
    }

    // and finally the payload
    writer.write_all(payload).map_err(E::from)?;

    Ok(())
}
///Returns the size of the packet when it is serialized
fn final_size<B>(builder: &PacketBuilderStep<B>, payload_size: usize) -> usize {
    use crate::NetHeaders::*;
    use crate::TransportHeader::*;
    use crate::VlanHeader::*;
    (match builder.state.link_header {
        Some(ref header) => header.header_len(),
        None => 0,
    }) + match builder.state.vlan_header {
        Some(Single(_)) => SingleVlanHeader::LEN,
        Some(Double(_)) => SingleVlanHeader::LEN * 2,
        None => 0,
    } + match builder.state.net_header {
        Some(Ipv4(ref value, ref ext)) => value.header_len() + ext.header_len(),
        Some(Ipv6(_, ref ext)) => Ipv6Header::LEN + ext.header_len(),
        Some(Arp(ref packet)) => packet.packet_len(),
        None => 0,
    } + match builder.state.transport_header {
        Some(Icmpv4(ref value)) => value.header_len(),
        Some(Icmpv6(ref value)) => value.header_len(),
        Some(Udp(_)) => UdpHeader::LEN,
        Some(Tcp(ref value)) => value.header_len(),
        None => 0,
    } + payload_size
}

#[cfg(test)]
mod white_box_tests {
    use super::*;
    use alloc::vec::Vec;

    //white box tests that need internal access
    #[test]
    fn size() {
        assert_eq!(
            0,
            PacketBuilderStep::<UdpHeader> {
                state: PacketImpl {
                    link_header: None,
                    net_header: None,
                    vlan_header: None,
                    transport_header: None,
                },
                _marker: marker::PhantomData::<UdpHeader> {}
            }
            .size(0)
        );
    }

    #[test]
    #[should_panic]
    fn final_write_panic_missing_ip() {
        let mut writer = Vec::new();
        final_write_with_net::<_, _, BuildVecWriteError>(
            PacketBuilderStep::<UdpHeader> {
                state: PacketImpl {
                    link_header: None,
                    net_header: None,
                    vlan_header: None,
                    transport_header: None,
                },
                _marker: marker::PhantomData::<UdpHeader> {},
            },
            &mut VecWriter(&mut writer),
            &[],
        )
        .unwrap();
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::test_gens::*;
    use alloc::{vec, vec::Vec};
    use proptest::prelude::*;
    use std::io::Read;

    #[test]
    fn eth_arp() {
        let expected_header = ArpPacket::new(
            ArpHardwareId::ETHERNET,
            EtherType::IPV4,
            ArpOperation::REQUEST,
            &[20, 30, 40, 50, 60, 70],
            &[10, 1, 1, 5],
            &[00, 01, 02, 03, 04, 05],
            &[192, 168, 1, 2],
        )
        .unwrap();

        let mut serialized = Vec::new();

        let pkg = PacketBuilder::ethernet2(
            [0x00, 0x1b, 0x21, 0x0f, 0x91, 0x9b],
            [0xde, 0xad, 0xc0, 0x00, 0xff, 0xee],
        )
        .arp(expected_header.clone());

        let target_size = pkg.size();
        pkg.write(&mut serialized).unwrap();

        // validate that the predicted size was matching
        assert_eq!(serialized.len(), target_size);

        // deserialize each part of the message and check it
        use std::io::Cursor;
        let mut cursor = Cursor::new(&serialized);

        // ethernet 2 header
        assert_eq!(
            Ethernet2Header::read(&mut cursor).unwrap(),
            Ethernet2Header {
                source: [0x00, 0x1b, 0x21, 0x0f, 0x91, 0x9b],
                destination: [0xde, 0xad, 0xc0, 0x00, 0xff, 0xee],
                ether_type: ether_type::ARP
            }
        );

        // arp packet
        assert_eq!(ArpPacket::read(&mut cursor).unwrap(), expected_header);
    }

    #[test]
    fn eth_vlan_arp() {
        let expected_arp = ArpPacket::new(
            ArpHardwareId::ETHERNET,
            EtherType::IPV4,
            ArpOperation::REQUEST,
            &[20, 30, 40, 50, 60, 70],
            &[10, 1, 1, 5],
            &[00, 01, 02, 03, 04, 05],
            &[192, 168, 1, 2],
        )
        .unwrap();
        let vlan = SingleVlanHeader {
            pcp: VlanPcp::ZERO,
            drop_eligible_indicator: false,
            vlan_id: VlanId::try_new(123).unwrap(),
            ether_type: EtherType(0), // should get overwritten
        };

        let mut serialized = Vec::new();

        let pkg = PacketBuilder::ethernet2(
            [0x00, 0x1b, 0x21, 0x0f, 0x91, 0x9b],
            [0xde, 0xad, 0xc0, 0x00, 0xff, 0xee],
        )
        .vlan(VlanHeader::Single(vlan.clone()))
        .arp(expected_arp.clone());

        let target_size = pkg.size();
        pkg.write(&mut serialized).unwrap();

        // validate that the predicted size was matching
        assert_eq!(serialized.len(), target_size);

        // deserialize each part of the message and check it
        use std::io::Cursor;
        let mut cursor = Cursor::new(&serialized);

        // ethernet 2 header
        assert_eq!(
            Ethernet2Header::read(&mut cursor).unwrap(),
            Ethernet2Header {
                source: [0x00, 0x1b, 0x21, 0x0f, 0x91, 0x9b],
                destination: [0xde, 0xad, 0xc0, 0x00, 0xff, 0xee],
                ether_type: ether_type::VLAN_TAGGED_FRAME
            }
        );

        // vlan header
        let mut expected_vlan = vlan.clone();
        expected_vlan.ether_type = EtherType::ARP;
        assert_eq!(SingleVlanHeader::read(&mut cursor).unwrap(), expected_vlan);

        // arp packet
        assert_eq!(ArpPacket::read(&mut cursor).unwrap(), expected_arp);
    }

    #[test]
    fn eth_ipv4_udp() {
        //generate
        let in_payload = [24, 25, 26, 27];
        let mut serialized = Vec::new();
        PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
            .ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .udp(22, 23)
            .write(&mut serialized, &in_payload)
            .unwrap();

        //check the deserialized size
        let expected_ip_size: usize = UdpHeader::LEN + in_payload.len();
        assert_eq!(
            expected_ip_size + Ethernet2Header::LEN + Ipv4Header::MIN_LEN,
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::Cursor;
        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ethernet 2 header
        assert_eq!(
            Ethernet2Header::read(&mut cursor).unwrap(),
            Ethernet2Header {
                source: [1, 2, 3, 4, 5, 6],
                destination: [7, 8, 9, 10, 11, 12],
                ether_type: ether_type::IPV4
            }
        );

        //ip header
        let ip_actual = Ipv4Header::read(&mut cursor).unwrap();
        let mut ip_expected = Ipv4Header::new(
            expected_ip_size as u16,
            21, //ttl
            ip_number::UDP,
            [13, 14, 15, 16],
            [17, 18, 19, 20],
        )
        .unwrap();
        ip_expected.header_checksum = ip_expected.calc_header_checksum();
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv4_checksum(22, 23, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    #[cfg(feature = "alloc")]
    fn write_to_vec_empty() {
        let payload = [1, 2, 3, 4];
        let mut written = Vec::new();
        let builder = PacketBuilder::ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21).udp(22, 23);
        let expected_len = builder.size(payload.len());

        builder.write_to_vec(&mut written, &payload).unwrap();

        assert_eq!(written.len(), expected_len);

        let mut expected = Vec::new();
        PacketBuilder::ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .udp(22, 23)
            .write(&mut expected, &payload)
            .unwrap();
        assert_eq!(written, expected);
    }

    #[test]
    #[cfg(feature = "alloc")]
    fn write_to_vec_with_existing_content() {
        let payload = [1, 2, 3, 4];
        let prefix = vec![0xaa, 0xbb, 0xcc];
        let mut written = prefix.clone();

        PacketBuilder::ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .udp(22, 23)
            .write_to_vec(&mut written, &payload)
            .unwrap();

        assert_eq!(&written[..prefix.len()], prefix.as_slice());

        let mut expected_packet = Vec::new();
        PacketBuilder::ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .udp(22, 23)
            .write(&mut expected_packet, &payload)
            .unwrap();
        assert_eq!(&written[prefix.len()..], expected_packet.as_slice());
    }

    #[test]
    fn write_to_slice_success() {
        let payload = [1, 2, 3, 4];

        let mut expected = Vec::new();
        PacketBuilder::ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .udp(22, 23)
            .write(&mut expected, &payload)
            .unwrap();
        let required = expected.len();

        let mut buffer = vec![0x55; required + 4];
        let written = PacketBuilder::ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .udp(22, 23)
            .write_to_slice(&mut buffer, &payload)
            .unwrap();

        assert_eq!(written, required);
        assert_eq!(&buffer[..written], expected.as_slice());
        assert_eq!(&buffer[written..], &[0x55, 0x55, 0x55, 0x55]);
    }

    #[test]
    fn write_to_slice_too_small() {
        let payload = [1, 2, 3, 4];
        let builder = PacketBuilder::ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21).udp(22, 23);
        let required = builder.size(payload.len());
        let mut buffer = vec![0u8; required - 1];

        let actual = builder.write_to_slice(&mut buffer, &payload).unwrap_err();
        let expected = BuildSliceWriteError::Space(required);
        assert_eq!(actual, expected);
    }

    #[test]
    fn linuxsll_ipv4_udp() {
        //generate
        let in_payload = [24, 25, 26, 27];
        let mut serialized = Vec::new();
        PacketBuilder::linux_sll(LinuxSllPacketType::OUTGOING, 6, [7, 8, 9, 10, 11, 12, 0, 0])
            .ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .udp(22, 23)
            .write(&mut serialized, &in_payload)
            .unwrap();

        //check the deserialized size
        let expected_ip_size: usize = UdpHeader::LEN + in_payload.len();
        assert_eq!(
            expected_ip_size + LinuxSllHeader::LEN + Ipv4Header::MIN_LEN,
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::Cursor;
        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ethernet 2 header
        assert_eq!(
            LinuxSllHeader::read(&mut cursor).unwrap(),
            LinuxSllHeader {
                packet_type: LinuxSllPacketType::OUTGOING,
                arp_hrd_type: ArpHardwareId::ETHERNET,
                sender_address_valid_length: 6,
                sender_address: [7, 8, 9, 10, 11, 12, 0, 0],
                protocol_type: LinuxSllProtocolType::EtherType(EtherType::IPV4)
            }
        );

        //ip header
        let ip_actual = Ipv4Header::read(&mut cursor).unwrap();
        let mut ip_expected = Ipv4Header::new(
            expected_ip_size as u16,
            21, //ttl
            ip_number::UDP,
            [13, 14, 15, 16],
            [17, 18, 19, 20],
        )
        .unwrap();
        ip_expected.header_checksum = ip_expected.calc_header_checksum();
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv4_checksum(22, 23, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn linuxsll_arp() {
        let expected_arp = ArpPacket::new(
            ArpHardwareId::ETHERNET,
            EtherType::IPV4,
            ArpOperation::REQUEST,
            &[20, 30, 40, 50, 60, 70],
            &[10, 1, 1, 5],
            &[00, 01, 02, 03, 04, 05],
            &[192, 168, 1, 2],
        )
        .unwrap();

        // build packet
        let builder =
            PacketBuilder::linux_sll(LinuxSllPacketType::OUTGOING, 6, [7, 8, 9, 10, 11, 12, 0, 0])
                .arp(expected_arp.clone());

        let predicted_size = builder.size();

        let mut serialized = Vec::with_capacity(builder.size());
        builder.write(&mut serialized).unwrap();

        // validate predicted size
        assert_eq!(predicted_size, serialized.len());

        // deserialize each part of the message and check it
        use std::io::Cursor;
        let mut cursor = Cursor::new(&serialized);

        // linux sll header
        assert_eq!(
            LinuxSllHeader::read(&mut cursor).unwrap(),
            LinuxSllHeader {
                packet_type: LinuxSllPacketType::OUTGOING,
                arp_hrd_type: ArpHardwareId::ETHERNET,
                sender_address_valid_length: 6,
                sender_address: [7, 8, 9, 10, 11, 12, 0, 0],
                protocol_type: LinuxSllProtocolType::EtherType(EtherType::ARP)
            }
        );

        // arp
        assert_eq!(ArpPacket::read(&mut cursor).unwrap(), expected_arp);
    }

    #[test]
    fn ipv4() {
        let auth_ext = IpAuthHeader::new(0.into(), 1, 2, &[3, 4, 5, 6]).unwrap();

        //generate
        let in_payload = [22, 23, 24, 25];
        let mut serialized = Vec::new();
        let builder = PacketBuilder::ip(IpHeaders::Ipv4(
            Ipv4Header::new(
                in_payload.len() as u16,
                21,
                0.into(),
                [13, 14, 15, 16],
                [17, 18, 19, 20],
            )
            .unwrap(),
            Ipv4Extensions {
                auth: Some(auth_ext.clone()),
            },
        ));

        // check size
        assert_eq!(
            builder.size(in_payload.len()),
            Ipv4Header::MIN_LEN + auth_ext.header_len() + in_payload.len()
        );

        // write
        serialized.reserve(builder.size(in_payload.len()));
        builder
            .write(&mut serialized, 200.into(), &in_payload)
            .unwrap();

        //check the deserialized size
        assert_eq!(
            Ipv4Header::MIN_LEN + auth_ext.header_len() + in_payload.len(),
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::{Cursor, Read};

        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ip header
        let ip_actual = Ipv4Header::read(&mut cursor).unwrap();
        let mut ip_expected = Ipv4Header::new(
            (auth_ext.header_len() + in_payload.len()) as u16,
            21,              //ttl
            ip_number::AUTH, // should have been set
            [13, 14, 15, 16],
            [17, 18, 19, 20],
        )
        .unwrap();
        ip_expected.header_checksum = ip_expected.calc_header_checksum();
        assert_eq!(ip_actual, ip_expected);

        // auth header
        let auth_actual = IpAuthHeader::read(&mut cursor).unwrap();
        assert_eq!(
            auth_actual,
            IpAuthHeader::new(
                200.into(), // ip number should have been set
                1,
                2,
                &[3, 4, 5, 6]
            )
            .unwrap()
        );

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn ipv6() {
        let auth_ext = IpAuthHeader::new(0.into(), 1, 2, &[3, 4, 5, 6]).unwrap();

        //generate
        let in_payload = [48, 49, 50, 51];
        let mut serialized = Vec::new();
        let builder = PacketBuilder::ip(IpHeaders::Ipv6(
            Ipv6Header {
                traffic_class: 0,
                flow_label: Ipv6FlowLabel::ZERO,
                payload_length: in_payload.len() as u16,
                next_header: 0.into(),
                hop_limit: 47,
                source: [
                    11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
                ],
                destination: [
                    31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
                ],
            },
            Ipv6Extensions {
                hop_by_hop_options: None,
                destination_options: None,
                routing: None,
                fragment: None,
                auth: Some(auth_ext.clone()),
            },
        ));

        // check size
        assert_eq!(
            builder.size(in_payload.len()),
            Ipv6Header::LEN + auth_ext.header_len() + in_payload.len()
        );

        // write
        builder
            .write(&mut serialized, 200.into(), &in_payload)
            .unwrap();

        //check the deserialized size
        assert_eq!(
            Ipv6Header::LEN + auth_ext.header_len() + in_payload.len(),
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::{Cursor, Read};

        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ip header
        let ip_actual = Ipv6Header::read(&mut cursor).unwrap();
        let ip_expected = Ipv6Header {
            traffic_class: 0,
            flow_label: Ipv6FlowLabel::ZERO,
            payload_length: (auth_ext.header_len() + in_payload.len()) as u16,
            next_header: ip_number::AUTH, // should have been set
            hop_limit: 47,
            source: [
                11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
            ],
            destination: [
                31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
            ],
        };

        assert_eq!(ip_actual, ip_expected);

        // auth header
        let auth_actual = IpAuthHeader::read(&mut cursor).unwrap();
        assert_eq!(
            auth_actual,
            IpAuthHeader::new(
                200.into(), // ip number should have been set
                1,
                2,
                &[3, 4, 5, 6]
            )
            .unwrap()
        );

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn ipv4_udp() {
        //generate
        let in_payload = [24, 25, 26, 27];
        let mut serialized = Vec::new();
        PacketBuilder::ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .udp(22, 23)
            .write(&mut serialized, &in_payload)
            .unwrap();

        //check the deserialized size
        let expected_ip_size: usize = UdpHeader::LEN + in_payload.len();
        assert_eq!(expected_ip_size + Ipv4Header::MIN_LEN, serialized.len());

        //deserialize and check that everything is as expected
        use std::io::{Cursor, Read};

        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ip header
        let ip_actual = Ipv4Header::read(&mut cursor).unwrap();
        let mut ip_expected = Ipv4Header::new(
            expected_ip_size as u16,
            21, //ttl
            ip_number::UDP,
            [13, 14, 15, 16],
            [17, 18, 19, 20],
        )
        .unwrap();
        ip_expected.header_checksum = ip_expected.calc_header_checksum();
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv4_checksum(22, 23, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn ipv6_udp() {
        //generate
        let in_payload = [24, 25, 26, 27];
        let mut serialized = Vec::new();
        PacketBuilder::ipv6(
            //source
            [
                11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
            ],
            //destination
            [
                31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
            ],
            //hop_limit
            47,
        )
        .udp(22, 23)
        .write(&mut serialized, &in_payload)
        .unwrap();

        //check the deserialized size
        let expected_ip_size: usize = UdpHeader::LEN + in_payload.len();
        assert_eq!(expected_ip_size + Ipv6Header::LEN, serialized.len());

        //deserialize and check that everything is as expected
        use std::io::{Cursor, Read};

        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ip header
        let ip_actual = Ipv6Header::read(&mut cursor).unwrap();
        let ip_expected = Ipv6Header {
            traffic_class: 0,
            flow_label: Ipv6FlowLabel::ZERO,
            payload_length: (UdpHeader::LEN + in_payload.len()) as u16,
            next_header: ip_number::UDP,
            hop_limit: 47,
            source: [
                11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
            ],
            destination: [
                31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
            ],
        };

        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv6_checksum(22, 23, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn ipv4_custom_udp() {
        //generate
        let in_payload = [24, 25, 26, 27];
        let mut serialized = Vec::new();
        PacketBuilder::ip(IpHeaders::Ipv4(
            Ipv4Header::new(
                0,                //payload_len will be replaced during write
                12,               //time_to_live
                ip_number::TCP,   //will be replaced during write
                [13, 14, 15, 16], //source
                [17, 18, 19, 20], //destination
            )
            .unwrap(),
            Default::default(),
        ))
        .udp(22, 23)
        .write(&mut serialized, &in_payload)
        .unwrap();

        //check the deserialized size
        let expected_ip_size: usize = UdpHeader::LEN + in_payload.len();
        assert_eq!(expected_ip_size + Ipv4Header::MIN_LEN, serialized.len());

        //deserialize and check that everything is as expected
        use std::io::{Cursor, Read};

        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ip header
        let ip_actual = Ipv4Header::read(&mut cursor).unwrap();
        let mut ip_expected = Ipv4Header::new(
            expected_ip_size as u16,
            12, //ttl
            ip_number::UDP,
            [13, 14, 15, 16],
            [17, 18, 19, 20],
        )
        .unwrap();
        ip_expected.header_checksum = ip_expected.calc_header_checksum();
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv4_checksum(22, 23, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn eth_ipv6_udp() {
        //generate
        let in_payload = [50, 51, 52, 53];
        let mut serialized = Vec::new();
        PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
            .ipv6(
                [
                    11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
                ],
                [
                    31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
                ],
                47,
            )
            .udp(48, 49)
            .write(&mut serialized, &in_payload)
            .unwrap();

        //check the deserialized size
        assert_eq!(
            Ethernet2Header::LEN + Ipv6Header::LEN + UdpHeader::LEN + in_payload.len(),
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::Cursor;
        use std::io::Read;
        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ethernet 2 header
        assert_eq!(
            Ethernet2Header::read(&mut cursor).unwrap(),
            Ethernet2Header {
                source: [1, 2, 3, 4, 5, 6],
                destination: [7, 8, 9, 10, 11, 12],
                ether_type: ether_type::IPV6
            }
        );

        //ip header
        let ip_actual = Ipv6Header::read(&mut cursor).unwrap();
        let ip_expected = Ipv6Header {
            traffic_class: 0,
            flow_label: Ipv6FlowLabel::ZERO,
            payload_length: (UdpHeader::LEN + in_payload.len()) as u16,
            next_header: ip_number::UDP,
            hop_limit: 47,
            source: [
                11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
            ],
            destination: [
                31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
            ],
        };
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv6_checksum(48, 49, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn linuxsll_ipv6_udp() {
        //generate
        let in_payload = [50, 51, 52, 53];
        let mut serialized = Vec::new();
        PacketBuilder::linux_sll(LinuxSllPacketType::OUTGOING, 6, [7, 8, 9, 10, 11, 12, 0, 0])
            .ipv6(
                [
                    11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
                ],
                [
                    31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
                ],
                47,
            )
            .udp(48, 49)
            .write(&mut serialized, &in_payload)
            .unwrap();

        //check the deserialized size
        assert_eq!(
            LinuxSllHeader::LEN + Ipv6Header::LEN + UdpHeader::LEN + in_payload.len(),
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::Cursor;
        use std::io::Read;
        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ethernet 2 header
        assert_eq!(
            LinuxSllHeader::read(&mut cursor).unwrap(),
            LinuxSllHeader {
                packet_type: LinuxSllPacketType::OUTGOING,
                arp_hrd_type: ArpHardwareId::ETHERNET,
                sender_address_valid_length: 6,
                sender_address: [7, 8, 9, 10, 11, 12, 0, 0],
                protocol_type: LinuxSllProtocolType::EtherType(EtherType::IPV6)
            }
        );

        //ip header
        let ip_actual = Ipv6Header::read(&mut cursor).unwrap();
        let ip_expected = Ipv6Header {
            traffic_class: 0,
            flow_label: Ipv6FlowLabel::ZERO,
            payload_length: (UdpHeader::LEN + in_payload.len()) as u16,
            next_header: ip_number::UDP,
            hop_limit: 47,
            source: [
                11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
            ],
            destination: [
                31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
            ],
        };
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv6_checksum(48, 49, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn eth_single_vlan_ipv4_udp() {
        //generate
        let in_payload = [50, 51, 52, 53];
        let mut serialized = Vec::new();
        PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
            .single_vlan(0x123.try_into().unwrap())
            .ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .udp(48, 49)
            .write(&mut serialized, &in_payload)
            .unwrap();

        //check the deserialized size

        //check the deserialized size
        let expected_ip_size: usize = UdpHeader::LEN + in_payload.len();
        assert_eq!(
            expected_ip_size + Ethernet2Header::LEN + Ipv4Header::MIN_LEN + SingleVlanHeader::LEN,
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::Cursor;
        use std::io::Read;
        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ethernet 2 header
        assert_eq!(
            Ethernet2Header::read(&mut cursor).unwrap(),
            Ethernet2Header {
                source: [1, 2, 3, 4, 5, 6],
                destination: [7, 8, 9, 10, 11, 12],
                ether_type: ether_type::VLAN_TAGGED_FRAME
            }
        );

        //vlan header
        assert_eq!(
            SingleVlanHeader::read(&mut cursor).unwrap(),
            SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: 0x123.try_into().unwrap(),
                ether_type: ether_type::IPV4
            }
        );

        //ip header
        let ip_actual = Ipv4Header::read(&mut cursor).unwrap();
        let mut ip_expected = Ipv4Header::new(
            expected_ip_size as u16, //payload_len
            21,                      //ttl
            ip_number::UDP,
            [13, 14, 15, 16],
            [17, 18, 19, 20],
        )
        .unwrap();
        ip_expected.header_checksum = ip_expected.calc_header_checksum();
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv4_checksum(48, 49, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn eth_double_vlan_ipv6_udp() {
        //generate
        let in_payload = [50, 51, 52, 53];
        let mut serialized = Vec::new();
        PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
            .double_vlan(0x123.try_into().unwrap(), 0x234.try_into().unwrap())
            .ipv6(
                [
                    11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
                ],
                [
                    31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
                ],
                47,
            )
            .udp(48, 49)
            .write(&mut serialized, &in_payload)
            .unwrap();

        //check the deserialized size
        assert_eq!(
            Ethernet2Header::LEN
                + SingleVlanHeader::LEN * 2
                + Ipv6Header::LEN
                + UdpHeader::LEN
                + in_payload.len(),
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::Cursor;
        use std::io::Read;

        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ethernet 2 header
        assert_eq!(
            Ethernet2Header::read(&mut cursor).unwrap(),
            Ethernet2Header {
                source: [1, 2, 3, 4, 5, 6],
                destination: [7, 8, 9, 10, 11, 12],
                ether_type: ether_type::PROVIDER_BRIDGING,
            }
        );

        //outer vlan header
        assert_eq!(
            SingleVlanHeader::read(&mut cursor).unwrap(),
            SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: 0x123.try_into().unwrap(),
                ether_type: ether_type::VLAN_TAGGED_FRAME
            }
        );

        //inner vlan header
        assert_eq!(
            SingleVlanHeader::read(&mut cursor).unwrap(),
            SingleVlanHeader {
                pcp: VlanPcp::ZERO,
                drop_eligible_indicator: false,
                vlan_id: 0x234.try_into().unwrap(),
                ether_type: ether_type::IPV6
            }
        );

        //ip header
        let ip_actual = Ipv6Header::read(&mut cursor).unwrap();
        let ip_expected = Ipv6Header {
            traffic_class: 0,
            flow_label: Ipv6FlowLabel::ZERO,
            payload_length: (UdpHeader::LEN + in_payload.len()) as u16,
            next_header: ip_number::UDP,
            hop_limit: 47,
            source: [
                11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
            ],
            destination: [
                31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
            ],
        };
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv6_checksum(48, 49, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn eth_ip_udp() {
        //generate
        let in_payload = [50, 51, 52, 53];
        let mut serialized = Vec::new();
        PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
            .ip(IpHeaders::Ipv6(
                Ipv6Header {
                    traffic_class: 1,
                    flow_label: 2.try_into().unwrap(),
                    payload_length: (UdpHeader::LEN + in_payload.len()) as u16,
                    next_header: ip_number::UDP,
                    hop_limit: 47,
                    source: [
                        11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
                    ],
                    destination: [
                        31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
                    ],
                },
                Default::default(),
            ))
            .udp(48, 49)
            .write(&mut serialized, &in_payload)
            .unwrap();

        //check the deserialized size
        assert_eq!(
            Ethernet2Header::LEN + Ipv6Header::LEN + UdpHeader::LEN + in_payload.len(),
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::Cursor;
        use std::io::Read;

        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ethernet 2 header
        assert_eq!(
            Ethernet2Header::read(&mut cursor).unwrap(),
            Ethernet2Header {
                source: [1, 2, 3, 4, 5, 6],
                destination: [7, 8, 9, 10, 11, 12],
                ether_type: ether_type::IPV6
            }
        );

        //ip header
        let ip_actual = Ipv6Header::read(&mut cursor).unwrap();
        let ip_expected = Ipv6Header {
            traffic_class: 1,
            flow_label: 2.try_into().unwrap(),
            payload_length: (UdpHeader::LEN + in_payload.len()) as u16,
            next_header: ip_number::UDP,
            hop_limit: 47,
            source: [
                11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
            ],
            destination: [
                31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
            ],
        };
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv6_checksum(48, 49, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn linuxsll_ip_udp() {
        //generate
        let in_payload = [50, 51, 52, 53];
        let mut serialized = Vec::new();
        PacketBuilder::linux_sll(LinuxSllPacketType::OUTGOING, 6, [7, 8, 9, 10, 11, 12, 0, 0])
            .ip(IpHeaders::Ipv6(
                Ipv6Header {
                    traffic_class: 1,
                    flow_label: 2.try_into().unwrap(),
                    payload_length: (UdpHeader::LEN + in_payload.len()) as u16,
                    next_header: ip_number::UDP,
                    hop_limit: 47,
                    source: [
                        11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
                    ],
                    destination: [
                        31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
                    ],
                },
                Default::default(),
            ))
            .udp(48, 49)
            .write(&mut serialized, &in_payload)
            .unwrap();

        //check the deserialized size
        assert_eq!(
            LinuxSllHeader::LEN + Ipv6Header::LEN + UdpHeader::LEN + in_payload.len(),
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::Cursor;
        use std::io::Read;

        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ethernet 2 header
        assert_eq!(
            LinuxSllHeader::read(&mut cursor).unwrap(),
            LinuxSllHeader {
                packet_type: LinuxSllPacketType::OUTGOING,
                arp_hrd_type: ArpHardwareId::ETHERNET,
                sender_address_valid_length: 6,
                sender_address: [7, 8, 9, 10, 11, 12, 0, 0],
                protocol_type: LinuxSllProtocolType::EtherType(EtherType::IPV6)
            }
        );

        //ip header
        let ip_actual = Ipv6Header::read(&mut cursor).unwrap();
        let ip_expected = Ipv6Header {
            traffic_class: 1,
            flow_label: 2.try_into().unwrap(),
            payload_length: (UdpHeader::LEN + in_payload.len()) as u16,
            next_header: ip_number::UDP,
            hop_limit: 47,
            source: [
                11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
            ],
            destination: [
                31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
            ],
        };
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv6_checksum(48, 49, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    #[test]
    fn eth_vlan_ip_udp() {
        //generate
        let in_payload = [50, 51, 52, 53];
        let mut serialized = Vec::new();
        PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
            .vlan(VlanHeader::Single(SingleVlanHeader {
                pcp: 1.try_into().unwrap(),
                drop_eligible_indicator: true,
                vlan_id: 0x123.try_into().unwrap(),
                ether_type: 0.into(), //should be overwritten
            }))
            .ip(IpHeaders::Ipv6(
                Ipv6Header {
                    traffic_class: 1,
                    flow_label: 2.try_into().unwrap(),
                    payload_length: (UdpHeader::LEN + in_payload.len()) as u16,
                    next_header: ip_number::UDP,
                    hop_limit: 47,
                    source: [
                        11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
                    ],
                    destination: [
                        31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
                    ],
                },
                Default::default(),
            ))
            .udp(48, 49)
            .write(&mut serialized, &in_payload)
            .unwrap();

        //check the deserialized size
        assert_eq!(
            Ethernet2Header::LEN
                + SingleVlanHeader::LEN
                + Ipv6Header::LEN
                + UdpHeader::LEN
                + in_payload.len(),
            serialized.len()
        );

        //deserialize and check that everything is as expected
        use std::io::Cursor;
        use std::io::Read;

        //deserialize each part of the message and check it
        let mut cursor = Cursor::new(&serialized);

        //ethernet 2 header
        assert_eq!(
            Ethernet2Header::read(&mut cursor).unwrap(),
            Ethernet2Header {
                source: [1, 2, 3, 4, 5, 6],
                destination: [7, 8, 9, 10, 11, 12],
                ether_type: ether_type::VLAN_TAGGED_FRAME
            }
        );

        //outer vlan header
        assert_eq!(
            SingleVlanHeader::read(&mut cursor).unwrap(),
            SingleVlanHeader {
                pcp: 1.try_into().unwrap(),
                drop_eligible_indicator: true,
                vlan_id: 0x123.try_into().unwrap(),
                ether_type: ether_type::IPV6
            }
        );

        //ip header
        let ip_actual = Ipv6Header::read(&mut cursor).unwrap();
        let ip_expected = Ipv6Header {
            traffic_class: 1,
            flow_label: 2.try_into().unwrap(),
            payload_length: (UdpHeader::LEN + in_payload.len()) as u16,
            next_header: ip_number::UDP,
            hop_limit: 47,
            source: [
                11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26,
            ],
            destination: [
                31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46,
            ],
        };
        assert_eq!(ip_actual, ip_expected);

        //udp header
        let udp_actual = UdpHeader::read(&mut cursor).unwrap();
        let udp_expected =
            UdpHeader::with_ipv6_checksum(48, 49, &ip_expected, &in_payload).unwrap();
        assert_eq!(udp_actual, udp_expected);

        //payload
        let mut actual_payload: [u8; 4] = [0; 4];
        cursor.read_exact(&mut actual_payload).unwrap();
        assert_eq!(actual_payload, in_payload);
    }

    proptest! {
        #[test]
        fn tcp_ipv4(ref input in tcp_any()) {

            //payload
            let in_payload = [24,25,26,27];

            //ip v4 header
            let mut ip_expected = Ipv4Header::new(
                in_payload.len() as u16 + input.header_len_u16(),
                21, //ttl
                ip_number::TCP,
                [13,14,15,16],
                [17,18,19,20]
            ).unwrap();
            ip_expected.header_checksum = ip_expected.calc_header_checksum();

            //generated the expected output
            let expected = {
                let mut expected = input.clone();
                //replace urg & ack if the flags are not set
                if !expected.ack {
                    expected.acknowledgment_number = 0;
                }
                if !expected.urg {
                    expected.urgent_pointer = 0;
                }
                //calculate the checksum
                expected.checksum = expected.calc_checksum_ipv4(&ip_expected, &in_payload[..]).unwrap();
                //done
                expected
            };

            //generate
            let serialized = {

                //create builder
                let mut builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                                                .ipv4([13,14,15,16], [17,18,19,20], 21)
                                                .tcp(input.source_port,
                                                    input.destination_port,
                                                    input.sequence_number,
                                                    input.window_size)
                                                .options_raw(input.options.as_slice()).unwrap();
                //set the flags
                if input.ns {
                    builder = builder.ns();
                }
                if input.fin {
                    builder = builder.fin();
                }
                if input.syn {
                    builder = builder.syn();
                }
                if input.rst {
                    builder = builder.rst();
                }
                if input.psh {
                    builder = builder.psh();
                }
                if input.ack {
                    builder = builder.ack(input.acknowledgment_number);
                }
                if input.urg {
                    builder = builder.urg(input.urgent_pointer);
                }
                if input.ece {
                    builder = builder.ece();
                }
                if input.cwr {
                    builder = builder.cwr();
                }

                let mut serialized = Vec::new();
                builder.write(&mut serialized, &in_payload).unwrap();
                serialized
            };

            //deserialize and check that everything is as expected
            use std::io::Cursor;
            use std::io::Read;
            //deserialize each part of the message and check it
            let mut cursor = Cursor::new(&serialized);

            //ethernet 2 header
            assert_eq!(Ethernet2Header::read(&mut cursor).unwrap(),
                    Ethernet2Header{
                            source: [1,2,3,4,5,6],
                            destination: [7,8,9,10,11,12],
                            ether_type: ether_type::IPV4
                    });

            //ip header
            let ip_actual = Ipv4Header::read(&mut cursor).unwrap();
            assert_eq!(ip_actual,
                    ip_expected);

            //tcp header
            assert_eq!(TcpHeader::read(&mut cursor).unwrap(),
                    expected);

            //payload
            let mut actual_payload: [u8;4] = [0;4];
            cursor.read_exact(&mut actual_payload).unwrap();
            assert_eq!(actual_payload, in_payload);
        }
    }

    proptest! {
        #[test]
        fn tcp_ipv6(ref input in tcp_any()) {

            //payload
            let in_payload = [24,25,26,27];

            //ip v4 header
            let ip_expected = Ipv6Header{
                traffic_class: 0,
                flow_label: Ipv6FlowLabel::ZERO,
                payload_length: (input.header_len() as usize + in_payload.len()) as u16,
                next_header: ip_number::TCP,
                hop_limit: 47,
                source: [11,12,13,14,15,16,17,18,19,10,21,22,23,24,25,26],
                destination: [31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46]
            };

            //generated the expected output
            let expected = {
                let mut expected = input.clone();
                //replace urg & ack if the flags are not set
                if !expected.ack {
                    expected.acknowledgment_number = 0;
                }
                if !expected.urg {
                    expected.urgent_pointer = 0;
                }
                //calculate the checksum
                expected.checksum = expected.calc_checksum_ipv6(&ip_expected, &in_payload[..]).unwrap();
                //done
                expected
            };

            //generate
            let serialized = {

                //create builder
                let mut builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                                                .ipv6([11,12,13,14,15,16,17,18,19,10,21,22,23,24,25,26],
                                                    [31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46],
                                                    47,
                                                )
                                                .tcp(input.source_port,
                                                    input.destination_port,
                                                    input.sequence_number,
                                                    input.window_size)
                                                .options_raw(input.options.as_slice()).unwrap();
                //set the flags
                if input.ns {
                    builder = builder.ns();
                }
                if input.fin {
                    builder = builder.fin();
                }
                if input.syn {
                    builder = builder.syn();
                }
                if input.rst {
                    builder = builder.rst();
                }
                if input.psh {
                    builder = builder.psh();
                }
                if input.ack {
                    builder = builder.ack(input.acknowledgment_number);
                }
                if input.urg {
                    builder = builder.urg(input.urgent_pointer);
                }
                if input.ece {
                    builder = builder.ece();
                }
                if input.cwr {
                    builder = builder.cwr();
                }

                let mut serialized = Vec::new();
                builder.write(&mut serialized, &in_payload).unwrap();
                serialized
            };

            //deserialize and check that everything is as expected
            use std::io::Cursor;
            use std::io::Read;
            //deserialize each part of the message and check it
            let mut cursor = Cursor::new(&serialized);

            //ethernet 2 header
            assert_eq!(Ethernet2Header::read(&mut cursor).unwrap(),
                    Ethernet2Header{
                            source: [1,2,3,4,5,6],
                            destination: [7,8,9,10,11,12],
                            ether_type: ether_type::IPV6
                    });

            //ip header
            let ip_actual = Ipv6Header::read(&mut cursor).unwrap();
            assert_eq!(ip_actual,
                    ip_expected);

            //tcp header
            assert_eq!(TcpHeader::read(&mut cursor).unwrap(),
                    expected);

            //payload
            let mut actual_payload: [u8;4] = [0;4];
            cursor.read_exact(&mut actual_payload).unwrap();
            assert_eq!(actual_payload, in_payload);
        }
    }

    #[test]
    fn eth_ipv4_tcp_options() {
        let mut serialized = Vec::new();

        use crate::TcpOptionElement::*;
        let options = vec![MaximumSegmentSize(1234), Noop];

        PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
            .ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .tcp(1, 2, 3, 4)
            .options(&options)
            .unwrap()
            .write(&mut serialized, &[])
            .unwrap();

        let decoded = PacketHeaders::from_ethernet_slice(&serialized[..]).unwrap();
        let dec_options: Vec<Result<TcpOptionElement, TcpOptionReadError>> = decoded
            .transport
            .unwrap()
            .tcp()
            .unwrap()
            .options_iterator()
            .collect();
        assert_eq!(&[Ok(MaximumSegmentSize(1234)), Ok(Noop)], &dec_options[..]);
    }

    #[test]
    fn eth_ipv4_tcp_header() {
        let mut serialized = Vec::new();

        let tcp_header = TcpHeader {
            source_port: 1234,
            destination_port: 2345,
            sequence_number: 3456,
            acknowledgment_number: 4567,
            ..Default::default()
        };

        PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
            .ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
            .tcp_header(tcp_header.clone())
            .write(&mut serialized, &[])
            .unwrap();

        let decoded = PacketHeaders::from_ethernet_slice(&serialized[..]).unwrap();

        let mut expected = tcp_header;
        expected.checksum = expected
            .calc_checksum_ipv4_raw([13, 14, 15, 16], [17, 18, 19, 20], &[])
            .unwrap();

        assert_eq!(decoded.transport, Some(TransportHeader::Tcp(expected)));
    }

    #[test]
    fn size() {
        //ipv4 no vlan ethernet
        assert_eq!(
            Ethernet2Header::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN + 123,
            PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
                .ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
                .udp(22, 23)
                .size(123)
        );

        //ipv6 no vlan ethernet
        assert_eq!(
            Ethernet2Header::LEN + Ipv6Header::LEN + UdpHeader::LEN + 123,
            PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
                .ipv6(
                    [11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26],
                    [31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46],
                    47,
                )
                .udp(22, 23)
                .size(123)
        );

        //ipv4 linux_sll
        assert_eq!(
            LinuxSllHeader::LEN + Ipv4Header::MIN_LEN + UdpHeader::LEN + 123,
            PacketBuilder::linux_sll(LinuxSllPacketType::OUTGOING, 6, [7, 8, 9, 10, 11, 12, 0, 0])
                .ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
                .udp(22, 23)
                .size(123)
        );

        //ipv6 linux_sll
        assert_eq!(
            LinuxSllHeader::LEN + Ipv6Header::LEN + UdpHeader::LEN + 123,
            PacketBuilder::linux_sll(LinuxSllPacketType::OUTGOING, 6, [7, 8, 9, 10, 11, 12, 0, 0])
                .ipv6(
                    [11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26],
                    [31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46],
                    47,
                )
                .udp(22, 23)
                .size(123)
        );

        //ipv4 single vlan ethernet
        assert_eq!(
            Ethernet2Header::LEN
                + SingleVlanHeader::LEN
                + Ipv4Header::MIN_LEN
                + UdpHeader::LEN
                + 123,
            PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
                .single_vlan(0x123.try_into().unwrap())
                .ipv4([13, 14, 15, 16], [17, 18, 19, 20], 21)
                .udp(22, 23)
                .size(123)
        );

        //ipv6 double vlan ethernet
        assert_eq!(
            Ethernet2Header::LEN
                + SingleVlanHeader::LEN * 2
                + Ipv6Header::LEN
                + UdpHeader::LEN
                + 123,
            PacketBuilder::ethernet2([1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11, 12])
                .double_vlan(0x123.try_into().unwrap(), 0x234.try_into().unwrap())
                .ipv6(
                    [11, 12, 13, 14, 15, 16, 17, 18, 19, 10, 21, 22, 23, 24, 25, 26],
                    [31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46],
                    47,
                )
                .udp(22, 23)
                .size(123)
        );
    }

    proptest! {
        #[test]
        fn size_tcp(ref input in tcp_any()) {

            assert_eq!(Ethernet2Header::LEN +
                    Ipv4Header::MIN_LEN +
                    input.header_len() as usize +
                    123,

                    PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                                    .ipv4([13,14,15,16], [17,18,19,20], 21)
                                    .tcp(input.source_port,
                                        input.destination_port,
                                        input.sequence_number,
                                        input.window_size)
                                    .options_raw(input.options.as_slice()).unwrap()
                                    .size(123));
        }
    }

    proptest! {
        #[test]
        fn ipv4_icmpv4(
            ipv4_source in any::<[u8;4]>(),
            ipv4_dest in any::<[u8;4]>(),
            ipv4_time_to_live in any::<u8>(),
            icmpv4_type_u8 in 15u8..u8::MAX,
            icmpv4_code_u8 in any::<u8>(),
            icmpv4_bytes5to8 in any::<[u8;4]>(),
            icmpv4 in icmpv4_type_any(),
            echo_id in any::<u16>(),
            echo_seq in any::<u16>(),
            payload in proptest::collection::vec(any::<u8>(), 0..64),
        ) {
            let test_builder = |builder: PacketBuilderStep<Icmpv4Header>, icmpv4_type: Icmpv4Type| {
                use crate::Icmpv4Type::*;
                let adapted_payload = match &icmpv4_type {
                    TimestampRequest(_) |
                    TimestampReply(_) => &[],
                    _ => &payload[..],
                };
                let icmp_expected = Icmpv4Header::with_checksum(icmpv4_type, &adapted_payload);
                let ip_expected = {
                    let mut expected_ipv4 = Ipv4Header::new(
                        (icmp_expected.header_len() + adapted_payload.len()) as u16,
                        ipv4_time_to_live,
                        ip_number::ICMP,
                        ipv4_source,
                        ipv4_dest
                    ).unwrap();
                    expected_ipv4.header_checksum = expected_ipv4.calc_header_checksum();
                    expected_ipv4
                };

                // test builder.size()
                assert_eq!(
                    builder.size(adapted_payload.len()),
                    Ethernet2Header::LEN +
                    Ipv4Header::MIN_LEN +
                    icmp_expected.header_len() +
                    adapted_payload.len()
                );

                // test builder.write()
                let mut buffer = Vec::<u8>::with_capacity(builder.size(adapted_payload.len()));
                builder.write(&mut buffer, adapted_payload).unwrap();

                // decode packets
                let actual = PacketHeaders::from_ethernet_slice(&buffer).unwrap();

                // check the packets could be decoded
                assert_eq!(
                    Some(LinkHeader::Ethernet2(Ethernet2Header{
                        source: [1,2,3,4,5,6],
                        destination: [7,8,9,10,11,12],
                        ether_type: ether_type::IPV4
                    })),
                    actual.link
                );
                assert_eq!(
                    Some(NetHeaders::Ipv4(ip_expected, Default::default())),
                    actual.net
                );
                assert_eq!(
                    Some(TransportHeader::Icmpv4(icmp_expected)),
                    actual.transport
                );
                assert_eq!(actual.payload.slice(), adapted_payload);
            };

            // icmpv4
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv4(ipv4_source, ipv4_dest, ipv4_time_to_live)
                    .icmpv4(icmpv4.clone());

                test_builder(
                    builder,
                    icmpv4
                );
            }

            // icmpv4_raw
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv4(ipv4_source, ipv4_dest, ipv4_time_to_live)
                    .icmpv4_raw(icmpv4_type_u8, icmpv4_code_u8, icmpv4_bytes5to8);

                test_builder(
                    builder,
                    Icmpv4Type::Unknown{
                        type_u8: icmpv4_type_u8,
                        code_u8: icmpv4_code_u8,
                        bytes5to8: icmpv4_bytes5to8,
                    }
                );
            }

            // icmpv4_echo_request
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv4(ipv4_source, ipv4_dest, ipv4_time_to_live)
                    .icmpv4_echo_request(echo_id, echo_seq);

                test_builder(
                    builder,
                    Icmpv4Type::EchoRequest(IcmpEchoHeader{
                        id: echo_id,
                        seq: echo_seq,
                    })
                );
            }

            // icmp4_echo_reply
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv4(ipv4_source, ipv4_dest, ipv4_time_to_live)
                    .icmpv4_echo_reply(echo_id, echo_seq);

                test_builder(
                    builder,
                    Icmpv4Type::EchoReply(IcmpEchoHeader{
                        id: echo_id,
                        seq: echo_seq,
                    })
                );
            }
        }
    }

    proptest! {
        #[test]
        fn ipv4_icmpv6(
            ipv4_source in any::<[u8;4]>(),
            ipv4_dest in any::<[u8;4]>(),
            ipv4_time_to_live in any::<u8>(),
            icmpv6_type_u8 in 162u8..u8::MAX,
            icmpv6_code_u8 in any::<u8>(),
            icmpv6_bytes5to8 in any::<[u8;4]>(),
            icmpv6 in icmpv6_type_any(),
            echo_id in any::<u16>(),
            echo_seq in any::<u16>(),
            payload in proptest::collection::vec(any::<u8>(), 0..64),
        ) {
            let test_builder = |builder: PacketBuilderStep<Icmpv6Header>, icmpv6_type: Icmpv6Type| {
                // test builder.size()
                assert_eq!(
                    builder.size(payload.len()),
                    Ethernet2Header::LEN +
                    Ipv4Header::MIN_LEN +
                    icmpv6_type.header_len() +
                    payload.len()
                );

                // test builder.write()
                let mut buffer = Vec::<u8>::with_capacity(builder.size(payload.len()));
                // should trigger an error, was it is not possible to calculate the checksum
                assert!(builder.write(&mut buffer, &payload).is_err());
            };

            // icmpv6
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv4(ipv4_source, ipv4_dest, ipv4_time_to_live)
                    .icmpv6(icmpv6.clone());

                test_builder(
                    builder,
                    icmpv6
                );
            }

            // icmpv6_raw
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv4(ipv4_source, ipv4_dest, ipv4_time_to_live)
                    .icmpv6_raw(icmpv6_type_u8, icmpv6_code_u8, icmpv6_bytes5to8);

                test_builder(
                    builder,
                    Icmpv6Type::Unknown{
                        type_u8: icmpv6_type_u8,
                        code_u8: icmpv6_code_u8,
                        bytes5to8: icmpv6_bytes5to8,
                    }
                );
            }

            // icmpv6_echo_request
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv4(ipv4_source, ipv4_dest, ipv4_time_to_live)
                    .icmpv6_echo_request(echo_id, echo_seq);

                test_builder(
                    builder,
                    Icmpv6Type::EchoRequest(IcmpEchoHeader{
                        id: echo_id,
                        seq: echo_seq,
                    })
                );
            }

            // icmp4_echo_reply
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv4(ipv4_source, ipv4_dest, ipv4_time_to_live)
                    .icmpv6_echo_reply(echo_id, echo_seq);

                test_builder(
                    builder,
                    Icmpv6Type::EchoReply(IcmpEchoHeader{
                        id: echo_id,
                        seq: echo_seq,
                    })
                );
            }
        }
    }

    proptest! {
        #[test]
        fn ipv6_icmpv4(
            ipv6_source in any::<[u8;16]>(),
            ipv6_dest in any::<[u8;16]>(),
            ipv6_hop_limit in any::<u8>(),
            icmpv4_type_u8 in 15u8..u8::MAX,
            icmpv4_code_u8 in any::<u8>(),
            icmpv4_bytes5to8 in any::<[u8;4]>(),
            icmpv4 in icmpv4_type_any(),
            echo_id in any::<u16>(),
            echo_seq in any::<u16>(),
            payload in proptest::collection::vec(any::<u8>(), 0..64),
        ) {
            let test_builder = |builder: PacketBuilderStep<Icmpv4Header>, icmpv4_type: Icmpv4Type| {

                use Icmpv4Type::*;
                let adapted_payload = match icmpv4_type {
                    TimestampRequest(_) | TimestampReply(_) => &[],
                    _ => &payload[..],
                };

                let icmp_expected = Icmpv4Header::with_checksum(icmpv4_type, &adapted_payload);
                let ip_expected = Ipv6Header{
                    traffic_class: 0,
                    flow_label: Ipv6FlowLabel::ZERO,
                    payload_length: (icmp_expected.header_len() + adapted_payload.len()) as u16,
                    next_header: ip_number::ICMP,
                    hop_limit: ipv6_hop_limit,
                    source: ipv6_source,
                    destination: ipv6_dest
                };

                // test builder.size()
                assert_eq!(
                    builder.size(adapted_payload.len()),
                    Ethernet2Header::LEN +
                    Ipv6Header::LEN +
                    icmp_expected.header_len() +
                    adapted_payload.len()
                );

                // test builder.write()
                let mut buffer = Vec::<u8>::with_capacity(builder.size(adapted_payload.len()));
                builder.write(&mut buffer, adapted_payload).unwrap();

                // decode packets
                let actual = PacketHeaders::from_ethernet_slice(&buffer).unwrap();

                // check the packets could be decoded
                assert_eq!(
                    Some(LinkHeader::Ethernet2(Ethernet2Header{
                        source: [1,2,3,4,5,6],
                        destination: [7,8,9,10,11,12],
                        ether_type: ether_type::IPV6
                    })),
                    actual.link
                );
                assert_eq!(
                    Some(NetHeaders::Ipv6(ip_expected, Default::default())),
                    actual.net
                );
                assert_eq!(
                    Some(TransportHeader::Icmpv4(icmp_expected)),
                    actual.transport
                );
                assert_eq!(actual.payload.slice(), adapted_payload);
            };

            // icmpv4
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv6(ipv6_source, ipv6_dest, ipv6_hop_limit)
                    .icmpv4(icmpv4.clone());

                test_builder(
                    builder,
                    icmpv4
                );
            }

            // icmpv4_raw
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv6(ipv6_source, ipv6_dest, ipv6_hop_limit)
                    .icmpv4_raw(icmpv4_type_u8, icmpv4_code_u8, icmpv4_bytes5to8);

                test_builder(
                    builder,
                    Icmpv4Type::Unknown{
                        type_u8: icmpv4_type_u8,
                        code_u8: icmpv4_code_u8,
                        bytes5to8: icmpv4_bytes5to8,
                    }
                );
            }

            // icmpv4_echo_request
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv6(ipv6_source, ipv6_dest, ipv6_hop_limit)
                    .icmpv4_echo_request(echo_id, echo_seq);

                test_builder(
                    builder,
                    Icmpv4Type::EchoRequest(IcmpEchoHeader{
                        id: echo_id,
                        seq: echo_seq,
                    })
                );
            }

            // icmp4_echo_reply
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv6(ipv6_source, ipv6_dest, ipv6_hop_limit)
                    .icmpv4_echo_reply(echo_id, echo_seq);

                test_builder(
                    builder,
                    Icmpv4Type::EchoReply(IcmpEchoHeader{
                        id: echo_id,
                        seq: echo_seq,
                    })
                );
            }
        }
    }

    proptest! {
        #[test]
        fn ipv6_icmpv6(
            ipv6_source in any::<[u8;16]>(),
            ipv6_dest in any::<[u8;16]>(),
            ipv6_hop_limit in any::<u8>(),
            icmpv6_type_u8 in 162u8..u8::MAX,
            icmpv6_code_u8 in any::<u8>(),
            icmpv6_bytes5to8 in any::<[u8;4]>(),
            icmpv6 in icmpv6_type_any(),
            echo_id in any::<u16>(),
            echo_seq in any::<u16>(),
            payload in proptest::collection::vec(any::<u8>(), 0..64),
        ) {
            let test_builder = |builder: PacketBuilderStep<Icmpv6Header>, icmpv6_type: Icmpv6Type| {
                let icmp_expected = Icmpv6Header::with_checksum(
                    icmpv6_type,
                    ipv6_source,
                    ipv6_dest,
                    &payload
                ).unwrap();
                let ip_expected = Ipv6Header{
                    traffic_class: 0,
                    flow_label: Ipv6FlowLabel::ZERO,
                    payload_length: (icmp_expected.header_len() + payload.len()) as u16,
                    next_header: ip_number::IPV6_ICMP,
                    hop_limit: ipv6_hop_limit,
                    source: ipv6_source,
                    destination: ipv6_dest
                };

                // test builder.size()
                assert_eq!(
                    builder.size(payload.len()),
                    Ethernet2Header::LEN +
                    Ipv6Header::LEN +
                    icmp_expected.header_len() +
                    payload.len()
                );

                // test builder.write()
                let mut buffer = Vec::<u8>::with_capacity(builder.size(payload.len()));
                builder.write(&mut buffer, &payload).unwrap();

                // decode packets
                let actual = PacketHeaders::from_ethernet_slice(&buffer).unwrap();

                // check the packets could be decoded
                assert_eq!(
                    Some(LinkHeader::Ethernet2(Ethernet2Header{
                        source: [1,2,3,4,5,6],
                        destination: [7,8,9,10,11,12],
                        ether_type: ether_type::IPV6
                    })),
                    actual.link
                );
                assert_eq!(
                    Some(NetHeaders::Ipv6(ip_expected, Default::default())),
                    actual.net
                );
                assert_eq!(
                    Some(TransportHeader::Icmpv6(icmp_expected)),
                    actual.transport
                );
                assert_eq!(actual.payload.slice(), &payload);
            };

            // icmpv6
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv6(ipv6_source, ipv6_dest, ipv6_hop_limit)
                    .icmpv6(icmpv6.clone());

                test_builder(
                    builder,
                    icmpv6
                );
            }

            // icmpv6_raw
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv6(ipv6_source, ipv6_dest, ipv6_hop_limit)
                    .icmpv6_raw(icmpv6_type_u8, icmpv6_code_u8, icmpv6_bytes5to8);

                test_builder(
                    builder,
                    Icmpv6Type::Unknown{
                        type_u8: icmpv6_type_u8,
                        code_u8: icmpv6_code_u8,
                        bytes5to8: icmpv6_bytes5to8,
                    }
                );
            }

            // icmpv6_echo_request
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv6(ipv6_source, ipv6_dest, ipv6_hop_limit)
                    .icmpv6_echo_request(echo_id, echo_seq);

                test_builder(
                    builder,
                    Icmpv6Type::EchoRequest(IcmpEchoHeader{
                        id: echo_id,
                        seq: echo_seq,
                    })
                );
            }

            // icmp4_echo_reply
            {
                let builder = PacketBuilder::ethernet2([1,2,3,4,5,6],[7,8,9,10,11,12])
                    .ipv6(ipv6_source, ipv6_dest, ipv6_hop_limit)
                    .icmpv6_echo_reply(echo_id, echo_seq);

                test_builder(
                    builder,
                    Icmpv6Type::EchoReply(IcmpEchoHeader{
                        id: echo_id,
                        seq: echo_seq,
                    })
                );
            }
        }
    }
}
