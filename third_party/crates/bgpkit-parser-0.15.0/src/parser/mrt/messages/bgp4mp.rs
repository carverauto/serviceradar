use crate::error::ParserError;
use crate::models::*;
use crate::parser::bgp::messages::parse_bgp_message;
use crate::parser::{encode_asn, encode_ipaddr, ReadUtils};
use bytes::{Buf, BufMut, Bytes, BytesMut};
use std::convert::TryFrom;

/// Parse MRT BGP4MP type
///
/// RFC: <https://www.rfc-editor.org/rfc/rfc6396#section-4.4>
///
pub fn parse_bgp4mp(sub_type: u16, input: Bytes) -> Result<Bgp4MpEnum, ParserError> {
    let bgp4mp_type: Bgp4MpType = Bgp4MpType::try_from(sub_type)?;
    let msg: Bgp4MpEnum = match bgp4mp_type {
        Bgp4MpType::StateChange => Bgp4MpEnum::StateChange(parse_bgp4mp_state_change(
            input,
            AsnLength::Bits16,
            &bgp4mp_type,
        )?),
        Bgp4MpType::StateChangeAs4 => Bgp4MpEnum::StateChange(parse_bgp4mp_state_change(
            input,
            AsnLength::Bits32,
            &bgp4mp_type,
        )?),
        Bgp4MpType::Message | Bgp4MpType::MessageLocal => Bgp4MpEnum::Message(
            parse_bgp4mp_message(input, false, AsnLength::Bits16, &bgp4mp_type)?,
        ),
        Bgp4MpType::MessageAs4 | Bgp4MpType::MessageAs4Local => Bgp4MpEnum::Message(
            parse_bgp4mp_message(input, false, AsnLength::Bits32, &bgp4mp_type)?,
        ),
        Bgp4MpType::MessageAddpath | Bgp4MpType::MessageLocalAddpath => Bgp4MpEnum::Message(
            parse_bgp4mp_message(input, true, AsnLength::Bits16, &bgp4mp_type)?,
        ),
        Bgp4MpType::MessageAs4Addpath | Bgp4MpType::MessageLocalAs4Addpath => Bgp4MpEnum::Message(
            parse_bgp4mp_message(input, true, AsnLength::Bits32, &bgp4mp_type)?,
        ),
    };

    Ok(msg)
}

fn total_should_read(afi: &Afi, asn_len: &AsnLength, total_size: usize) -> usize {
    let ip_size = match afi {
        Afi::Ipv4 => 4 * 2,
        Afi::Ipv6 => 16 * 2,
        Afi::LinkState => 4 * 2, // Link-State uses IPv4 format for compatibility
    };
    let asn_size = match asn_len {
        AsnLength::Bits16 => 2 * 2,
        AsnLength::Bits32 => 2 * 4,
    };
    total_size - asn_size - 2 - 2 - ip_size
}
/*
   0                   1                   2                   3
   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |         Peer AS Number        |        Local AS Number        |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |        Interface Index        |        Address Family         |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Peer IP Address (variable)               |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Local IP Address (variable)              |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                    BGP Message... (variable)
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
*/
pub fn parse_bgp4mp_message(
    mut data: Bytes,
    add_path: bool,
    asn_len: AsnLength,
    msg_type: &Bgp4MpType,
) -> Result<Bgp4MpMessage, ParserError> {
    let total_size = data.len();

    let peer_asn: Asn = data.read_asn(asn_len)?;
    let local_asn: Asn = data.read_asn(asn_len)?;
    let interface_index: u16 = data.read_u16()?;
    let afi: Afi = data.read_afi()?;
    let peer_ip = data.read_address(&afi)?;
    let local_ip = data.read_address(&afi)?;

    let should_read = total_should_read(&afi, &asn_len, total_size);
    if should_read != data.remaining() {
        return Err(ParserError::TruncatedMsg(format!(
            "truncated bgp4mp message: should read {} bytes, have {} bytes available",
            should_read,
            data.remaining()
        )));
    }
    let bgp_message: BgpMessage = parse_bgp_message(&mut data, add_path, &asn_len)?;

    Ok(Bgp4MpMessage {
        msg_type: *msg_type,
        peer_asn,
        local_asn,
        interface_index,
        peer_ip,
        local_ip,
        bgp_message,
    })
}

impl Bgp4MpMessage {
    pub fn encode(&self, asn_len: AsnLength) -> Bytes {
        let mut bytes = BytesMut::new();
        bytes.extend(self.peer_asn.encode());
        bytes.extend(self.local_asn.encode());
        bytes.put_u16(self.interface_index);
        bytes.put_u16(address_family(&self.peer_ip));
        bytes.extend(encode_ipaddr(&self.peer_ip));
        bytes.extend(encode_ipaddr(&self.local_ip));
        bytes.extend(&self.bgp_message.encode(asn_len));
        bytes.freeze()
    }
}

/*
   0                   1                   2                   3
   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |         Peer AS Number        |        Local AS Number        |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |        Interface Index        |        Address Family         |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Peer IP Address (variable)               |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Local IP Address (variable)              |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |            Old State          |          New State            |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

   0                   1                   2                   3
   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                         Peer AS Number                        |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                         Local AS Number                       |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |        Interface Index        |        Address Family         |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Peer IP Address (variable)               |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Local IP Address (variable)              |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |            Old State          |          New State            |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
*/
pub fn parse_bgp4mp_state_change(
    mut input: Bytes,
    asn_len: AsnLength,
    msg_type: &Bgp4MpType,
) -> Result<Bgp4MpStateChange, ParserError> {
    let peer_asn: Asn = input.read_asn(asn_len)?;
    let local_asn: Asn = input.read_asn(asn_len)?;
    let interface_index: u16 = input.read_u16()?;
    let address_family: Afi = input.read_afi()?;
    let peer_ip = input.read_address(&address_family)?;
    let local_addr = input.read_address(&address_family)?;
    let old_state = BgpState::try_from(input.read_u16()?)?;
    let new_state = BgpState::try_from(input.read_u16()?)?;
    Ok(Bgp4MpStateChange {
        msg_type: *msg_type,
        peer_asn,
        local_asn,
        interface_index,
        peer_ip,
        local_addr,
        old_state,
        new_state,
    })
}

impl Bgp4MpStateChange {
    pub fn encode(&self, asn_len: AsnLength) -> Bytes {
        let mut bytes = BytesMut::new();
        bytes.extend(encode_asn(&self.peer_asn, &asn_len));
        bytes.extend(encode_asn(&self.local_asn, &asn_len));
        bytes.put_u16(self.interface_index);
        bytes.put_u16(address_family(&self.peer_ip));
        bytes.extend(encode_ipaddr(&self.peer_ip));
        bytes.extend(encode_ipaddr(&self.local_addr));
        bytes.put_u16(self.old_state as u16);
        bytes.put_u16(self.new_state as u16);
        bytes.freeze()
    }
}
