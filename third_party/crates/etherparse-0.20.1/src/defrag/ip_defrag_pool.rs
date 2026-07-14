use crate::{defrag::*, *};
use std::collections::HashMap;
use std::vec::Vec;

/// Pool of buffers to reconstruct multiple fragmented IP packets in
/// parallel (re-uses buffers to minimize allocations).
///
/// It differentiates the packets based on their inner & outer vlan as well as
/// source and destination ip address and allows the user to add their own
/// custom "channel id" type to further differentiate different streams.
/// The custom channel id can be used to
///
/// # This implementation is NOT safe against "Out of Memory" attacks
///
/// If you use the [`IpDefragPool`] in an untrusted environment an attacker could
/// cause an "out of memory error" by opening up multiple parallel TP streams,
/// never ending them and filling them up with as much data as possible.
///
/// Mitigations will hopefully be offered in future versions but if you have
/// take care right now you can still use [`IpDefragBuf`] directly and implement the
/// connection handling and mitigation yourself.
#[derive(Debug, Clone)]
pub struct IpDefragPool<Timestamp = (), CustomChannelId = ()>
where
    Timestamp: Sized + core::fmt::Debug + Clone,
    CustomChannelId: Sized + core::fmt::Debug + Clone + core::hash::Hash + Eq + PartialEq,
{
    /// Currently reconstructing IP packets.
    active: HashMap<IpFragId<CustomChannelId>, (IpDefragBuf, Timestamp)>,

    /// Data buffers that have finished receiving data and can be re-used.
    finished_data_bufs: Vec<Vec<u8>>,

    /// Section buffers that have finished receiving data and can be re-used.
    finished_section_bufs: Vec<Vec<IpFragRange>>,
}

impl<Timestamp, CustomChannelId> IpDefragPool<Timestamp, CustomChannelId>
where
    Timestamp: Sized + core::fmt::Debug + Clone,
    CustomChannelId: Sized + core::fmt::Debug + Clone + core::hash::Hash + Eq + PartialEq,
{
    pub fn new() -> IpDefragPool<Timestamp, CustomChannelId> {
        IpDefragPool {
            active: HashMap::new(),
            finished_data_bufs: Vec::new(),
            finished_section_bufs: Vec::new(),
        }
    }

    /// Add data from a sliced packet.
    pub fn process_sliced_packet(
        &mut self,
        slice: &SlicedPacket,
        timestamp: Timestamp,
        channel_id: CustomChannelId,
    ) -> Result<Option<IpDefragPayloadVec>, IpDefragError> {
        // extract the fragment related data and skip non-fragmented packets
        let (frag_id, offset, more_fragments, payload, is_ipv4) = match &slice.net {
            Some(NetSlice::Ipv4(ipv4)) => {
                let header = ipv4.header();
                if false == header.is_fragmenting_payload() {
                    // nothing to defragment here, skip packet
                    return Ok(None);
                }

                (
                    IpFragId {
                        vlan_ids: slice.vlan_ids(),
                        ip: IpFragVersionSpecId::Ipv4 {
                            source: header.source(),
                            destination: header.destination(),
                            identification: header.identification(),
                        },
                        payload_ip_number: ipv4.payload().ip_number,
                        channel_id,
                    },
                    header.fragments_offset(),
                    header.more_fragments(),
                    ipv4.payload(),
                    true,
                )
            }
            Some(NetSlice::Ipv6(ipv6)) => {
                // get fragmentation header
                let frag = {
                    let mut f = None;
                    for ext in ipv6.extensions().clone().into_iter() {
                        use Ipv6ExtensionSlice::*;
                        if let Fragment(frag_it) = ext {
                            f = Some(frag_it);
                            break;
                        }
                    }
                    if let Some(f) = f {
                        if f.is_fragmenting_payload() {
                            f.to_header()
                        } else {
                            // nothing to defragment here, skip packet
                            return Ok(None);
                        }
                    } else {
                        // nothing to defragment here, skip packet
                        return Ok(None);
                    }
                };

                // calculate frag id
                (
                    IpFragId {
                        vlan_ids: slice.vlan_ids(),
                        ip: IpFragVersionSpecId::Ipv6 {
                            source: ipv6.header().source(),
                            destination: ipv6.header().destination(),
                            identification: frag.identification,
                        },
                        payload_ip_number: ipv6.payload().ip_number,
                        channel_id,
                    },
                    frag.fragment_offset,
                    frag.more_fragments,
                    ipv6.payload(),
                    false,
                )
            }
            Some(NetSlice::Arp(_)) | None => {
                // nothing to defragment here, skip packet
                return Ok(None);
            }
        };

        // get the reconstruction buffer
        use std::collections::hash_map::Entry;
        match self.active.entry(frag_id) {
            Entry::Occupied(mut entry) => {
                let buf = entry.get_mut();
                buf.0.add(offset, more_fragments, payload.payload)?;
                buf.1 = timestamp;
                if buf.0.is_complete() {
                    let (defraged_payload, sections) = entry.remove().0.take_bufs();
                    self.finished_section_bufs.push(sections);
                    Ok(Some(IpDefragPayloadVec {
                        ip_number: payload.ip_number,
                        len_source: if is_ipv4 {
                            LenSource::Ipv4HeaderTotalLen
                        } else {
                            LenSource::Ipv6HeaderPayloadLen
                        },
                        payload: defraged_payload,
                    }))
                } else {
                    Ok(None)
                }
            }
            Entry::Vacant(entry) => {
                let data_buf = if let Some(mut d) = self.finished_data_bufs.pop() {
                    d.clear();
                    d
                } else {
                    Vec::with_capacity(payload.payload.len() * 2)
                };
                let sections = if let Some(mut s) = self.finished_section_bufs.pop() {
                    s.clear();
                    s
                } else {
                    Vec::with_capacity(4)
                };

                let mut defrag_buf = IpDefragBuf::new(payload.ip_number, data_buf, sections);
                match defrag_buf.add(offset, more_fragments, payload.payload) {
                    Ok(()) => {
                        // no need to check if the defrag is done as the
                        // packet can not be defragmented on initial add
                        // otherwise `is_fragmenting_payload` would have
                        // been false
                        entry.insert((defrag_buf, timestamp));
                        Ok(None)
                    }
                    Err(err) => {
                        // return the buffers
                        let (data_buf, sections) = defrag_buf.take_bufs();
                        self.finished_data_bufs.push(data_buf);
                        self.finished_section_bufs.push(sections);
                        Err(err)
                    }
                }
            }
        }
    }

    /// Returns a buffer to the pool so it can be re-used.
    pub fn return_buf(&mut self, buf: IpDefragPayloadVec) {
        self.finished_data_bufs.push(buf.payload);
    }

    /// Retains only the elements specified by the predicate.
    pub fn retain<F>(&mut self, f: F)
    where
        F: Fn(&Timestamp) -> bool,
    {
        if self.active.iter().any(|(_, (_, t))| false == f(t)) {
            self.active = self
                .active
                .drain()
                .filter_map(|(k, v)| {
                    if f(&v.1) {
                        Some((k, v))
                    } else {
                        let (data, sections) = v.0.take_bufs();
                        self.finished_data_bufs.push(data);
                        self.finished_section_bufs.push(sections);
                        None
                    }
                })
                .collect();
        }
    }
}

impl<Timestamp, CustomChannelId> Default for IpDefragPool<Timestamp, CustomChannelId>
where
    Timestamp: Sized + core::fmt::Debug + Clone,
    CustomChannelId: Sized + core::fmt::Debug + Clone + core::hash::Hash + Eq + PartialEq,
{
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod test {
    use std::cmp::max;

    use arrayvec::ArrayVec;

    use super::*;

    #[test]
    fn new() {
        {
            let pool = IpDefragPool::<(), ()>::new();
            assert_eq!(pool.active.len(), 0);
            assert_eq!(pool.finished_data_bufs.len(), 0);
            assert_eq!(pool.finished_section_bufs.len(), 0);
        }
        {
            let pool = IpDefragPool::<u32, (u32, u32)>::new();
            assert_eq!(pool.active.len(), 0);
            assert_eq!(pool.finished_data_bufs.len(), 0);
            assert_eq!(pool.finished_section_bufs.len(), 0);
        }
    }

    #[test]
    fn default() {
        {
            let pool: IpDefragPool<(), ()> = Default::default();
            assert_eq!(pool.active.len(), 0);
            assert_eq!(pool.finished_data_bufs.len(), 0);
            assert_eq!(pool.finished_section_bufs.len(), 0);
        }
        {
            let pool: IpDefragPool<u32, (u32, u32)> = Default::default();
            assert_eq!(pool.active.len(), 0);
            assert_eq!(pool.finished_data_bufs.len(), 0);
            assert_eq!(pool.finished_section_bufs.len(), 0);
        }
    }

    fn build_packet<CustomChannelId: core::hash::Hash + Eq + PartialEq + Clone + Sized>(
        id: IpFragId<CustomChannelId>,
        offset: u16,
        more: bool,
        payload: &[u8],
    ) -> Vec<u8> {
        let mut buf = Vec::with_capacity(
            Ethernet2Header::LEN
                + SingleVlanHeader::LEN
                + SingleVlanHeader::LEN
                + max(
                    Ipv4Header::MIN_LEN,
                    Ipv6Header::LEN + Ipv6FragmentHeader::LEN,
                )
                + payload.len(),
        );

        let ip_ether_type = match id.ip {
            IpFragVersionSpecId::Ipv4 {
                source: _,
                destination: _,
                identification: _,
            } => EtherType::IPV4,
            IpFragVersionSpecId::Ipv6 {
                source: _,
                destination: _,
                identification: _,
            } => EtherType::IPV6,
        };

        buf.extend_from_slice(
            &Ethernet2Header {
                source: [0; 6],
                destination: [0; 6],
                ether_type: if id.vlan_ids.is_empty() {
                    ip_ether_type
                } else {
                    EtherType::VLAN_TAGGED_FRAME
                },
            }
            .to_bytes(),
        );

        for (index, vlan_id) in id.vlan_ids.iter().enumerate() {
            buf.extend_from_slice(
                &SingleVlanHeader {
                    pcp: VlanPcp::try_new(0).unwrap(),
                    drop_eligible_indicator: false,
                    vlan_id: *vlan_id,
                    ether_type: if index < id.vlan_ids.len() - 1 {
                        EtherType::VLAN_TAGGED_FRAME
                    } else {
                        ip_ether_type
                    },
                }
                .to_bytes(),
            );
        }

        match id.ip {
            IpFragVersionSpecId::Ipv4 {
                source,
                destination,
                identification,
            } => {
                let mut header = Ipv4Header {
                    identification,
                    more_fragments: more,
                    fragment_offset: IpFragOffset::try_new(offset).unwrap(),
                    protocol: id.payload_ip_number,
                    source,
                    destination,
                    total_len: (Ipv4Header::MIN_LEN + payload.len()) as u16,
                    time_to_live: 2,
                    ..Default::default()
                };
                header.header_checksum = header.calc_header_checksum();
                buf.extend_from_slice(&header.to_bytes());
            }
            IpFragVersionSpecId::Ipv6 {
                source,
                destination,
                identification,
            } => {
                buf.extend_from_slice(
                    &Ipv6Header {
                        traffic_class: 0,
                        flow_label: Default::default(),
                        payload_length: (payload.len() + Ipv6FragmentHeader::LEN + 8) as u16,
                        next_header: IpNumber::IPV6_FRAGMENTATION_HEADER,
                        hop_limit: 2,
                        source,
                        destination,
                    }
                    .to_bytes(),
                );
                buf.extend_from_slice(
                    &Ipv6FragmentHeader {
                        next_header: IpNumber::IPV6_ROUTE_HEADER,
                        fragment_offset: IpFragOffset::try_new(offset).unwrap(),
                        more_fragments: more,
                        identification,
                    }
                    .to_bytes(),
                );
                buf.extend_from_slice(
                    &{
                        let mut h: Ipv6RawExtHeader = Default::default();
                        h.next_header = id.payload_ip_number;
                        h
                    }
                    .to_bytes(),
                );
            }
        }
        buf.extend_from_slice(payload);
        buf
    }

    #[test]
    fn process_sliced_packet() {
        // non ip packet
        {
            let mut pool = IpDefragPool::<(), ()>::new();
            let pslice = SlicedPacket {
                link: None,
                link_exts: ArrayVec::new_const(),
                net: None,
                transport: None,
            };
            let v = pool.process_sliced_packet(&pslice, (), ());
            assert_eq!(Ok(None), v);
            assert_eq!(pool.active.len(), 0);
            assert_eq!(pool.finished_data_bufs.len(), 0);
            assert_eq!(pool.finished_section_bufs.len(), 0);
        }

        // v4 non fragmented
        {
            let mut pool = IpDefragPool::<(), ()>::new();
            let pdata = build_packet(
                IpFragId {
                    vlan_ids: Default::default(),
                    ip: IpFragVersionSpecId::Ipv4 {
                        source: [0; 4],
                        destination: [0; 4],
                        identification: 0,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
                0,
                false,
                &UdpHeader {
                    source_port: 0,
                    destination_port: 0,
                    length: 0,
                    checksum: 0,
                }
                .to_bytes(),
            );
            let pslice = SlicedPacket::from_ethernet(&pdata).unwrap();
            let v = pool.process_sliced_packet(&pslice, (), ());
            assert_eq!(Ok(None), v);

            // check the effect had no effect
            assert_eq!(pool.active.len(), 0);
            assert_eq!(pool.finished_data_bufs.len(), 0);
            assert_eq!(pool.finished_section_bufs.len(), 0);
        }

        // v6 non fragmented
        {
            let mut pool = IpDefragPool::<(), ()>::new();
            let pdata = build_packet(
                IpFragId {
                    vlan_ids: Default::default(),
                    ip: IpFragVersionSpecId::Ipv6 {
                        source: [0; 16],
                        destination: [0; 16],
                        identification: 0,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
                0,
                false,
                &UdpHeader {
                    source_port: 0,
                    destination_port: 0,
                    length: 0,
                    checksum: 0,
                }
                .to_bytes(),
            );
            let pslice = SlicedPacket::from_ethernet(&pdata).unwrap();
            let v = pool.process_sliced_packet(&pslice, (), ());
            assert_eq!(Ok(None), v);

            // check the effect had no effect
            assert_eq!(pool.active.len(), 0);
            assert_eq!(pool.finished_data_bufs.len(), 0);
            assert_eq!(pool.finished_section_bufs.len(), 0);
        }

        // v4 & v6 basic test
        {
            let frag_ids = [
                // v4 (no vlan)
                IpFragId {
                    vlan_ids: Default::default(),
                    ip: IpFragVersionSpecId::Ipv4 {
                        source: [1, 2, 3, 4],
                        destination: [5, 6, 7, 8],
                        identification: 9,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
                // v4 (single vlan)
                IpFragId {
                    vlan_ids: {
                        let mut vlan_ids = ArrayVec::new_const();
                        vlan_ids.push(VlanId::try_new(12).unwrap());
                        vlan_ids
                    },
                    ip: IpFragVersionSpecId::Ipv4 {
                        source: [1, 2, 3, 4],
                        destination: [5, 6, 7, 8],
                        identification: 9,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
                // v4 (double vlan)
                IpFragId {
                    vlan_ids: {
                        let mut vlan_ids = ArrayVec::new_const();
                        vlan_ids.push(VlanId::try_new(12).unwrap());
                        vlan_ids.push(VlanId::try_new(13).unwrap());
                        vlan_ids
                    },
                    ip: IpFragVersionSpecId::Ipv4 {
                        source: [1, 2, 3, 4],
                        destination: [5, 6, 7, 8],
                        identification: 9,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
                // v6 (no vlan)
                IpFragId {
                    vlan_ids: Default::default(),
                    ip: IpFragVersionSpecId::Ipv6 {
                        source: [0; 16],
                        destination: [0; 16],
                        identification: 0,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
                // v6 (single vlan)
                IpFragId {
                    vlan_ids: {
                        let mut vlan_ids = ArrayVec::new_const();
                        vlan_ids.push(VlanId::try_new(12).unwrap());
                        vlan_ids
                    },
                    ip: IpFragVersionSpecId::Ipv6 {
                        source: [0; 16],
                        destination: [0; 16],
                        identification: 0,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
                // v6 (double vlan)
                IpFragId {
                    vlan_ids: {
                        let mut vlan_ids = ArrayVec::new_const();
                        vlan_ids.push(VlanId::try_new(12).unwrap());
                        vlan_ids.push(VlanId::try_new(13).unwrap());
                        vlan_ids
                    },
                    ip: IpFragVersionSpecId::Ipv6 {
                        source: [0; 16],
                        destination: [0; 16],
                        identification: 0,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
            ];

            let mut pool = IpDefragPool::<(), ()>::new();

            for frag_id in frag_ids {
                {
                    let pdata = build_packet(frag_id.clone(), 0, true, &[1, 2, 3, 4, 5, 6, 7, 8]);
                    let pslice = SlicedPacket::from_ethernet(&pdata).unwrap();
                    let v = pool.process_sliced_packet(&pslice, (), ());
                    assert_eq!(Ok(None), v);

                    // check the frag id was correctly calculated
                    assert_eq!(1, pool.active.len());
                    assert_eq!(pool.active.iter().next().unwrap().0, &frag_id);
                }

                {
                    let pdata = build_packet(
                        frag_id.clone(),
                        1,
                        true,
                        &[
                            9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
                        ],
                    );
                    let pslice = SlicedPacket::from_ethernet(&pdata).unwrap();
                    let v = pool.process_sliced_packet(&pslice, (), ());
                    assert_eq!(Ok(None), v);

                    // check the frag id was correctly calculated
                    assert_eq!(1, pool.active.len());
                    assert_eq!(pool.active.iter().next().unwrap().0, &frag_id);
                }

                {
                    let pdata = build_packet(frag_id.clone(), 3, false, &[25, 26]);
                    let pslice = SlicedPacket::from_ethernet(&pdata).unwrap();
                    let v = pool
                        .process_sliced_packet(&pslice, (), ())
                        .unwrap()
                        .unwrap();
                    assert_eq!(v.ip_number, IpNumber::UDP);
                    assert_eq!(
                        v.len_source,
                        if matches!(
                            frag_id.ip,
                            IpFragVersionSpecId::Ipv4 {
                                source: _,
                                destination: _,
                                identification: _
                            }
                        ) {
                            LenSource::Ipv4HeaderTotalLen
                        } else {
                            LenSource::Ipv6HeaderPayloadLen
                        }
                    );
                    assert_eq!(
                        v.payload,
                        &[
                            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
                            21, 22, 23, 24, 25, 26
                        ]
                    );

                    // there should be nothing left
                    assert_eq!(pool.active.len(), 0);
                    assert_eq!(pool.finished_data_bufs.len(), 0);
                    assert_eq!(pool.finished_section_bufs.len(), 1);

                    // return buffer
                    pool.return_buf(v);

                    assert_eq!(pool.active.len(), 0);
                    assert_eq!(pool.finished_data_bufs.len(), 1);
                    assert_eq!(pool.finished_section_bufs.len(), 1);
                }
            }
        }

        // ipv6 no frag header
        {
            // build packet without ipv6
            let pdata = {
                let mut v = Vec::with_capacity(Ipv6Header::LEN + UdpHeader::LEN + 16);
                v.extend_from_slice(
                    &Ipv6Header {
                        traffic_class: 0,
                        flow_label: Ipv6FlowLabel::try_new(0).unwrap(),
                        payload_length: UdpHeader::LEN_U16 + 16,
                        next_header: IpNumber::UDP,
                        hop_limit: 2,
                        source: [0; 16],
                        destination: [0; 16],
                    }
                    .to_bytes(),
                );
                v.extend_from_slice(
                    &UdpHeader {
                        source_port: 1234,
                        destination_port: 2345,
                        length: UdpHeader::LEN_U16 + 10,
                        checksum: 0,
                    }
                    .to_bytes(),
                );
                v.extend_from_slice(&[0; 16]);
                v
            };
            let slice = SlicedPacket::from_ip(&pdata).unwrap();

            let mut pool = IpDefragPool::<(), ()>::new();
            assert_eq!(Ok(None), pool.process_sliced_packet(&slice, (), ()));
            assert_eq!(pool.active.len(), 0);
            assert_eq!(pool.finished_data_bufs.len(), 0);
            assert_eq!(pool.finished_section_bufs.len(), 0);
        }

        // error in initial packet
        {
            let frag_ids = [
                // v4
                IpFragId {
                    vlan_ids: Default::default(),
                    ip: IpFragVersionSpecId::Ipv4 {
                        source: [1, 2, 3, 4],
                        destination: [5, 6, 7, 8],
                        identification: 9,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
                // v6
                IpFragId {
                    vlan_ids: Default::default(),
                    ip: IpFragVersionSpecId::Ipv6 {
                        source: [0; 16],
                        destination: [0; 16],
                        identification: 0,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
            ];
            let mut pool = IpDefragPool::<(), ()>::new();

            for frag_id in frag_ids {
                let pdata = build_packet(frag_id.clone(), 0, true, &[0; 7]);
                let pslice = SlicedPacket::from_ethernet(&pdata).unwrap();
                let v = pool.process_sliced_packet(&pslice, (), ());
                assert_eq!(
                    Err(IpDefragError::UnalignedFragmentPayloadLen {
                        offset: IpFragOffset::try_new(0).unwrap(),
                        payload_len: 7
                    }),
                    v
                );
                assert_eq!(0, pool.active.len());
            }
        }

        // error in followup packet
        {
            let frag_ids = [
                // v4
                IpFragId {
                    vlan_ids: Default::default(),
                    ip: IpFragVersionSpecId::Ipv4 {
                        source: [1, 2, 3, 4],
                        destination: [5, 6, 7, 8],
                        identification: 9,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
                // v6
                IpFragId {
                    vlan_ids: Default::default(),
                    ip: IpFragVersionSpecId::Ipv6 {
                        source: [0; 16],
                        destination: [0; 16],
                        identification: 0,
                    },
                    payload_ip_number: IpNumber::UDP,
                    channel_id: (),
                },
            ];

            for frag_id in frag_ids {
                let mut pool = IpDefragPool::<(), ()>::new();

                // initial packet
                {
                    let pdata = build_packet(frag_id.clone(), 0, true, &[1, 2, 3, 4, 5, 6, 7, 8]);
                    let pslice = SlicedPacket::from_ethernet(&pdata).unwrap();
                    let v = pool.process_sliced_packet(&pslice, (), ());
                    assert_eq!(Ok(None), v);

                    // check the frag id was correctly calculated
                    assert_eq!(1, pool.active.len());
                    assert_eq!(pool.active.iter().next().unwrap().0, &frag_id);
                }

                // follow up packet error
                {
                    let pdata = build_packet(
                        frag_id.clone(),
                        1,
                        true,
                        &[9, 10, 11, 12, 13, 14, 15, 16, 17],
                    );
                    let pslice = SlicedPacket::from_ethernet(&pdata).unwrap();
                    let v = pool.process_sliced_packet(&pslice, (), ());
                    assert_eq!(
                        Err(IpDefragError::UnalignedFragmentPayloadLen {
                            offset: IpFragOffset::try_new(1).unwrap(),
                            payload_len: 9
                        }),
                        v
                    );

                    // check the frag id was correctly calculated
                    assert_eq!(1, pool.active.len());
                    {
                        let p = pool.active.iter().next().unwrap();
                        assert_eq!(p.0, &frag_id);
                        assert_eq!(p.1 .0.data(), &[1, 2, 3, 4, 5, 6, 7, 8]);
                        assert_eq!(p.1 .0.sections()[0].start, 0);
                        assert_eq!(p.1 .0.sections()[0].end, 8);
                    }
                }
            }
        }
    }

    #[test]
    fn retain() {
        let frag_id_0 = IpFragId {
            vlan_ids: Default::default(),
            ip: IpFragVersionSpecId::Ipv4 {
                source: [1, 2, 3, 4],
                destination: [5, 6, 7, 8],
                identification: 0,
            },
            payload_ip_number: IpNumber::UDP,
            channel_id: (),
        };
        let frag_id_1 = IpFragId {
            vlan_ids: Default::default(),
            ip: IpFragVersionSpecId::Ipv4 {
                source: [1, 2, 3, 4],
                destination: [5, 6, 7, 8],
                identification: 1,
            },
            payload_ip_number: IpNumber::UDP,
            channel_id: (),
        };

        let mut pool = IpDefragPool::<u32, ()>::new();

        // packet timestamp 1
        {
            let pdata = build_packet(frag_id_0.clone(), 0, true, &[1, 2, 3, 4, 5, 6, 7, 8]);
            let pslice = SlicedPacket::from_ethernet(&pdata).unwrap();
            let v = pool.process_sliced_packet(&pslice, 1, ());
            assert_eq!(Ok(None), v);
        }
        // packet timestamp 2
        {
            let pdata = build_packet(frag_id_1.clone(), 0, true, &[1, 2, 3, 4, 5, 6, 7, 8]);
            let pslice = SlicedPacket::from_ethernet(&pdata).unwrap();
            let v = pool.process_sliced_packet(&pslice, 2, ());
            assert_eq!(Ok(None), v);
        }

        // check buffers are active
        assert_eq!(pool.active.len(), 2);
        assert_eq!(pool.finished_data_bufs.len(), 0);
        assert_eq!(pool.finished_section_bufs.len(), 0);

        // call retain without effect
        pool.retain(|ts| *ts > 0);
        assert_eq!(pool.active.len(), 2);
        assert_eq!(pool.finished_data_bufs.len(), 0);
        assert_eq!(pool.finished_section_bufs.len(), 0);

        // call retain and delete timestamp 1
        pool.retain(|ts| *ts > 1);
        assert_eq!(pool.active.len(), 1);
        assert_eq!(pool.finished_data_bufs.len(), 1);
        assert_eq!(pool.finished_section_bufs.len(), 1);
        assert_eq!(pool.active.iter().next().unwrap().0, &frag_id_1);
    }
}
