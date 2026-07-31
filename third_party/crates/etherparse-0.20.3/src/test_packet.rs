use crate::*;
use alloc::vec::Vec;
use arrayvec::ArrayVec;

#[derive(Clone)]
pub(crate) struct TestPacket {
    pub link: Option<LinkHeader>,
    pub link_exts: ArrayVec<LinkExtHeader, 3>,
    pub net: Option<NetHeaders>,
    pub transport: Option<TransportHeader>,
}

impl TestPacket {
    pub fn has_arp(&self) -> bool {
        self.net.as_ref().map(|v| v.is_arp()).unwrap_or(false)
    }

    pub fn len(&self, payload: &[u8]) -> usize {
        self.link.as_ref().map_or(0, |x| x.header_len())
            + self
                .link_exts
                .as_ref()
                .iter()
                .map(|x| x.header_len())
                .sum::<usize>()
            + self.net.as_ref().map_or(0, |x| x.header_len())
            + self.transport.as_ref().map_or(0, |x| x.header_len())
            + payload.len()
    }

    pub fn to_vec(&self, payload: &[u8]) -> Vec<u8> {
        let mut result = Vec::with_capacity(self.len(payload));
        if let Some(link) = &self.link {
            link.write(&mut result).unwrap();
        }
        for e in &self.link_exts {
            match e {
                LinkExtHeader::Vlan(s) => s.write(&mut result).unwrap(),
                LinkExtHeader::Macsec(m) => m.write(&mut result).unwrap(),
            }
        }
        if let Some(net) = &self.net {
            match net {
                NetHeaders::Ipv4(ipv4, exts) => {
                    ipv4.write_raw(&mut result).unwrap();
                    exts.write(&mut result, ipv4.protocol).unwrap();
                }
                NetHeaders::Ipv6(ipv6, exts) => {
                    ipv6.write(&mut result).unwrap();
                    exts.write(&mut result, ipv6.next_header).unwrap();
                }
                NetHeaders::Arp(arp) => {
                    arp.write(&mut result).unwrap();
                }
            }
        }
        if let Some(transport) = &self.transport {
            transport.write(&mut result).unwrap();
        }
        result.extend_from_slice(payload);
        result
    }

    pub fn set_ether_type(&mut self, ether_type: EtherType) {
        let mut next = ether_type;
        for e in self.link_exts.iter_mut().rev() {
            match e {
                LinkExtHeader::Vlan(s) => {
                    s.ether_type = next;
                    if next == ether_type::VLAN_TAGGED_FRAME {
                        next = ether_type::VLAN_DOUBLE_TAGGED_FRAME;
                    } else {
                        next = ether_type::VLAN_TAGGED_FRAME;
                    }
                }
                LinkExtHeader::Macsec(m) => {
                    m.ptype = MacsecPType::Unmodified(next);
                    next = ether_type::MACSEC;
                }
            }
        }
        if let Some(link) = &mut self.link {
            match link {
                LinkHeader::Ethernet2(ethernet) => ethernet.ether_type = next,
                LinkHeader::LinuxSll(linux_sll) => linux_sll.protocol_type.change_value(next.0),
            }
        }
    }

    pub fn set_payload_len(&mut self, payload_len: usize) {
        // link extensions
        {
            let mut last_len = self.net.as_ref().map(|v| v.header_len()).unwrap_or(0)
                + self.transport.as_ref().map(|v| v.header_len()).unwrap_or(0)
                + payload_len;
            for ext in self.link_exts.iter_mut().rev() {
                match ext {
                    LinkExtHeader::Vlan(h) => {
                        last_len += h.header_len();
                    }
                    LinkExtHeader::Macsec(h) => {
                        h.set_payload_len(last_len);
                        last_len += h.header_len();
                    }
                }
            }
        }

        // net layer
        use NetHeaders::*;
        match &mut self.net {
            None => {}
            Some(Ipv4(ref mut header, ref mut exts)) => {
                header
                    .set_payload_len(
                        exts.header_len()
                            + self.transport.as_ref().map_or(0, |t| t.header_len())
                            + payload_len,
                    )
                    .unwrap();
            }
            Some(Ipv6(ref mut header, ref mut exts)) => {
                header
                    .set_payload_length(
                        exts.header_len()
                            + self.transport.as_ref().map_or(0, |t| t.header_len())
                            + payload_len,
                    )
                    .unwrap();
            }
            Some(Arp(_)) => {}
        }

        // transport layer
        use TransportHeader::*;
        match &mut self.transport {
            None => {}
            Some(Udp(ref mut udp)) => {
                udp.length = udp.header_len_u16() + payload_len as u16;
            }
            Some(Tcp(_)) => {}
            Some(Icmpv4(_)) => {}
            Some(Icmpv6(_)) => {}
        }
    }

    /// Set the length relative to the end of the ip headers.
    pub fn set_payload_len_ip(&mut self, payload_len_from_ip_on: isize) {
        use NetHeaders::*;
        match self.net.as_mut().unwrap() {
            Ipv4(ref mut header, ref mut exts) => {
                header
                    .set_payload_len((exts.header_len() as isize + payload_len_from_ip_on) as usize)
                    .unwrap();
            }
            Ipv6(ref mut header, ref mut exts) => {
                header
                    .set_payload_length(
                        (exts.header_len() as isize + payload_len_from_ip_on) as usize,
                    )
                    .unwrap();
            }
            Arp(_) => {}
        }
    }

    /// Set the length relative to the end of the link extensions.
    pub fn set_payload_len_link_ext(&mut self, payload_len_from_ext_on: usize) {
        let mut payload_len = payload_len_from_ext_on;
        for ext in self.link_exts.iter_mut().rev() {
            match ext {
                LinkExtHeader::Vlan(v) => {
                    payload_len += v.header_len();
                }
                LinkExtHeader::Macsec(h) => {
                    h.set_payload_len(payload_len);
                    payload_len += h.header_len();
                }
            }
        }
    }

    pub fn is_ip_payload_fragmented(&self) -> bool {
        self.net.as_ref().map_or(false, |net| match net {
            NetHeaders::Ipv4(h, _) => h.is_fragmenting_payload(),
            NetHeaders::Ipv6(_, e) => e.is_fragmenting_payload(),
            NetHeaders::Arp(_) => false,
        })
    }
}
