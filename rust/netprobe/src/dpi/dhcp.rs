#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DhcpObservation {
    pub message_type: Option<DhcpMessageType>,
    pub option_order: Vec<u16>,
    pub parameter_request_list: Vec<u16>,
    pub vendor_class_present: bool,
}

impl DhcpObservation {
    #[allow(dead_code)]
    pub fn satori_message_type(&self) -> Option<&'static str> {
        self.message_type.map(DhcpMessageType::satori_name)
    }

    #[allow(dead_code)]
    pub fn option_order_csv(&self) -> String {
        csv_u16(&self.option_order)
    }

    #[allow(dead_code)]
    pub fn parameter_request_list_csv(&self) -> String {
        csv_u16(&self.parameter_request_list)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DhcpMessageType {
    Discover,
    Offer,
    Request,
    Decline,
    Ack,
    Nak,
    Release,
    Inform,
    Other(u8),
}

impl DhcpMessageType {
    #[allow(dead_code)]
    pub fn satori_name(self) -> &'static str {
        match self {
            Self::Discover => "Discover",
            Self::Offer => "Offer",
            Self::Request => "Request",
            Self::Decline => "Decline",
            Self::Ack => "Ack",
            Self::Nak => "Nak",
            Self::Release => "Release",
            Self::Inform => "Inform",
            Self::Other(_) => "Other",
        }
    }
}

const DHCPV4_MIN_LEN: usize = 240;
const DHCPV4_MAGIC_COOKIE_OFFSET: usize = 236;
const DHCPV4_OPTIONS_OFFSET: usize = 240;
const DHCPV4_MAGIC_COOKIE: [u8; 4] = [99, 130, 83, 99];
const DHCP_MESSAGE_TYPE_OPTION: u8 = 53;
const DHCP_PARAMETER_REQUEST_LIST_OPTION: u8 = 55;
const DHCP_VENDOR_CLASS_OPTION: u8 = 60;
const DHCP_END_OPTION: u8 = 255;
const DHCP_PAD_OPTION: u8 = 0;
const DHCPV6_OPTION_ORO: u16 = 6;
const DHCPV6_OPTION_VENDOR_CLASS: u16 = 16;

pub fn parse_dhcpv4(payload: &[u8]) -> Option<DhcpObservation> {
    if payload.len() < DHCPV4_MIN_LEN {
        return None;
    }
    if payload[DHCPV4_MAGIC_COOKIE_OFFSET..DHCPV4_OPTIONS_OFFSET] != DHCPV4_MAGIC_COOKIE {
        return None;
    }

    let mut observation = DhcpObservation {
        message_type: None,
        option_order: Vec::new(),
        parameter_request_list: Vec::new(),
        vendor_class_present: false,
    };
    let mut offset = DHCPV4_OPTIONS_OFFSET;

    while offset < payload.len() {
        let code = payload[offset];
        offset += 1;

        match code {
            DHCP_PAD_OPTION => continue,
            DHCP_END_OPTION => break,
            _ => {}
        }

        let length = usize::from(*payload.get(offset)?);
        offset += 1;
        let value = payload.get(offset..offset.checked_add(length)?)?;
        offset += length;
        observation.option_order.push(u16::from(code));

        match code {
            DHCP_MESSAGE_TYPE_OPTION if value.len() == 1 => {
                observation.message_type = Some(message_type(value[0]));
            }
            DHCP_PARAMETER_REQUEST_LIST_OPTION => {
                observation
                    .parameter_request_list
                    .extend(value.iter().copied().map(u16::from));
            }
            DHCP_VENDOR_CLASS_OPTION => observation.vendor_class_present = true,
            _ => {}
        }
    }

    if observation.message_type.is_none()
        && observation.option_order.is_empty()
        && observation.parameter_request_list.is_empty()
    {
        return None;
    }

    Some(observation)
}

pub fn parse_dhcpv6(payload: &[u8]) -> Option<DhcpObservation> {
    if payload.len() < 4 {
        return None;
    }

    let mut observation = DhcpObservation {
        message_type: Some(message_type(payload[0])),
        option_order: Vec::new(),
        parameter_request_list: Vec::new(),
        vendor_class_present: false,
    };
    let mut offset = 4usize;

    while offset + 4 <= payload.len() {
        let code = u16::from_be_bytes([payload[offset], payload[offset + 1]]);
        let length = usize::from(u16::from_be_bytes([
            payload[offset + 2],
            payload[offset + 3],
        ]));
        offset += 4;
        let value = payload.get(offset..offset.checked_add(length)?)?;
        offset += length;
        observation.option_order.push(code);

        match code {
            DHCPV6_OPTION_ORO => {
                for chunk in value.as_chunks::<2>().0 {
                    observation
                        .parameter_request_list
                        .push(u16::from_be_bytes(*chunk));
                }
            }
            DHCPV6_OPTION_VENDOR_CLASS => observation.vendor_class_present = true,
            _ => {}
        }
    }

    Some(observation)
}

fn message_type(value: u8) -> DhcpMessageType {
    match value {
        1 => DhcpMessageType::Discover,
        2 => DhcpMessageType::Offer,
        3 => DhcpMessageType::Request,
        4 => DhcpMessageType::Decline,
        5 => DhcpMessageType::Ack,
        6 => DhcpMessageType::Nak,
        7 => DhcpMessageType::Release,
        8 => DhcpMessageType::Inform,
        other => DhcpMessageType::Other(other),
    }
}

#[allow(dead_code)]
fn csv_u16(values: &[u16]) -> String {
    values
        .iter()
        .map(u16::to_string)
        .collect::<Vec<_>>()
        .join(",")
}

#[cfg(test)]
mod tests {
    use super::{DhcpMessageType, parse_dhcpv4, parse_dhcpv6};

    #[test]
    fn parses_dhcpv4_option_presence_without_option_values() {
        let observation = parse_dhcpv4(&dhcpv4_packet()).expect("valid DHCPv4 packet parses");

        assert_eq!(observation.message_type, Some(DhcpMessageType::Discover));
        assert_eq!(observation.option_order_csv(), "53,55,60,12");
        assert_eq!(observation.parameter_request_list_csv(), "1,3,6,15");
        assert!(observation.vendor_class_present);

        let debug = format!("{observation:?}");
        assert!(!debug.contains("secret-vendor-class"));
        assert!(!debug.contains("host-secret"));
    }

    #[test]
    fn parses_dhcpv6_option_presence_without_option_values() {
        let observation = parse_dhcpv6(&dhcpv6_packet()).expect("valid DHCPv6 packet parses");

        assert_eq!(observation.message_type, Some(DhcpMessageType::Discover));
        assert_eq!(observation.option_order_csv(), "6,16");
        assert_eq!(observation.parameter_request_list_csv(), "23,24");
        assert!(observation.vendor_class_present);

        let debug = format!("{observation:?}");
        assert!(!debug.contains("secret-vendor"));
    }

    #[test]
    fn rejects_truncated_or_cookie_less_dhcpv4() {
        assert!(parse_dhcpv4(&[0; 12]).is_none());

        let mut packet = dhcpv4_packet();
        packet[236..240].copy_from_slice(&[0, 0, 0, 0]);
        assert!(parse_dhcpv4(&packet).is_none());
    }

    fn dhcpv4_packet() -> Vec<u8> {
        let mut packet = vec![0u8; 240];
        packet[0] = 1;
        packet[1] = 1;
        packet[2] = 6;
        packet[236..240].copy_from_slice(&[99, 130, 83, 99]);
        packet.extend_from_slice(&[53, 1, 1]);
        packet.extend_from_slice(&[55, 4, 1, 3, 6, 15]);
        packet.extend_from_slice(&[60, 19]);
        packet.extend_from_slice(b"secret-vendor-class");
        packet.extend_from_slice(&[12, 11]);
        packet.extend_from_slice(b"host-secret");
        packet.push(255);
        packet
    }

    fn dhcpv6_packet() -> Vec<u8> {
        let mut packet = vec![1, 0xaa, 0xbb, 0xcc];
        packet.extend_from_slice(&6u16.to_be_bytes());
        packet.extend_from_slice(&4u16.to_be_bytes());
        packet.extend_from_slice(&23u16.to_be_bytes());
        packet.extend_from_slice(&24u16.to_be_bytes());
        packet.extend_from_slice(&16u16.to_be_bytes());
        packet.extend_from_slice(&13u16.to_be_bytes());
        packet.extend_from_slice(b"secret-vendor");
        packet
    }
}
