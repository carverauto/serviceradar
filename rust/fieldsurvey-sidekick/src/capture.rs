use crate::observation::{ManagementFrameType, SidekickObservation};

const RADIOTAP_PRESENT_EXT: u32 = 1 << 31;
const RADIOTAP_CHANNEL: u8 = 3;
const RADIOTAP_DBM_ANTSIGNAL: u8 = 5;
const RADIOTAP_DBM_ANTNOISE: u8 = 6;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedRadiotap {
    pub payload_offset: usize,
    pub frequency_mhz: Option<u32>,
    pub rssi_dbm: Option<i16>,
    pub noise_floor_dbm: Option<i16>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedManagementFrame {
    pub frame_type: ManagementFrameType,
    pub bssid: String,
    pub ssid: Option<String>,
    pub hidden_ssid: bool,
}

pub fn parse_radiotap(packet: &[u8]) -> Result<ParsedRadiotap, String> {
    if packet.len() < 8 {
        return Err("radiotap header too short".to_string());
    }

    if packet[0] != 0 {
        return Err(format!("unsupported radiotap version {}", packet[0]));
    }

    let header_len = u16::from_le_bytes([packet[2], packet[3]]) as usize;
    if header_len < 8 || header_len > packet.len() {
        return Err("invalid radiotap header length".to_string());
    }

    let mut present_words = Vec::new();
    let mut cursor = 4;
    loop {
        if cursor + 4 > header_len {
            return Err("radiotap present bitmap is truncated".to_string());
        }

        let present = u32::from_le_bytes([
            packet[cursor],
            packet[cursor + 1],
            packet[cursor + 2],
            packet[cursor + 3],
        ]);
        present_words.push(present);
        cursor += 4;

        if present & RADIOTAP_PRESENT_EXT == 0 {
            break;
        }
    }

    let mut frequency_mhz = None;
    let mut rssi_dbm = None;
    let mut noise_floor_dbm = None;

    for (word_idx, present) in present_words.iter().enumerate() {
        for bit in 0..31_u8 {
            if present & (1_u32 << bit) == 0 {
                continue;
            }

            let field_index = (word_idx as u8 * 32) + bit;
            let Some((align, len)) = radiotap_field_layout(field_index) else {
                continue;
            };

            cursor = align_cursor(cursor, align);
            if cursor + len > header_len {
                return Err(format!("radiotap field {field_index} is truncated"));
            }

            match field_index {
                RADIOTAP_CHANNEL => {
                    frequency_mhz =
                        Some(u16::from_le_bytes([packet[cursor], packet[cursor + 1]]) as u32);
                }
                RADIOTAP_DBM_ANTSIGNAL => {
                    rssi_dbm = Some(i8::from_ne_bytes([packet[cursor]]) as i16);
                }
                RADIOTAP_DBM_ANTNOISE => {
                    noise_floor_dbm = Some(i8::from_ne_bytes([packet[cursor]]) as i16);
                }
                _ => {}
            }

            cursor += len;
        }
    }

    Ok(ParsedRadiotap {
        payload_offset: header_len,
        frequency_mhz,
        rssi_dbm,
        noise_floor_dbm,
    })
}

pub fn parse_management_frame(frame: &[u8]) -> Result<ParsedManagementFrame, String> {
    if frame.len() < 24 {
        return Err("802.11 management frame is too short".to_string());
    }

    let frame_control = u16::from_le_bytes([frame[0], frame[1]]);
    let frame_kind = ((frame_control >> 2) & 0b11) as u8;
    let subtype = ((frame_control >> 4) & 0b1111) as u8;
    if frame_kind != 0 {
        return Err("802.11 frame is not a management frame".to_string());
    }

    let frame_type = match subtype {
        4 => ManagementFrameType::ProbeRequest,
        5 => ManagementFrameType::ProbeResponse,
        8 => ManagementFrameType::Beacon,
        _ => ManagementFrameType::Other,
    };

    let bssid = if matches!(frame_type, ManagementFrameType::ProbeRequest) {
        mac_to_string(&frame[10..16])
    } else {
        mac_to_string(&frame[16..22])
    };

    let ie_offset = match frame_type {
        ManagementFrameType::Beacon | ManagementFrameType::ProbeResponse => 36,
        ManagementFrameType::ProbeRequest => 24,
        ManagementFrameType::Other => {
            return Ok(ParsedManagementFrame {
                frame_type,
                bssid,
                ssid: None,
                hidden_ssid: true,
            });
        }
    };

    if frame.len() < ie_offset {
        return Err("802.11 management frame fixed parameters are truncated".to_string());
    }

    let ssid = parse_ssid_ie(&frame[ie_offset..]);
    let hidden_ssid = ssid
        .as_deref()
        .map(|value| value.is_empty())
        .unwrap_or(true);

    Ok(ParsedManagementFrame {
        frame_type,
        bssid,
        ssid: ssid.filter(|value| !value.is_empty()),
        hidden_ssid,
    })
}

pub fn observation_from_packet(
    packet: &[u8],
    sidekick_id: &str,
    radio_id: &str,
    interface_name: &str,
    captured_at_unix_nanos: i64,
    captured_at_monotonic_nanos: Option<u64>,
) -> Result<SidekickObservation, String> {
    let radiotap = parse_radiotap(packet)?;
    let management = parse_management_frame(&packet[radiotap.payload_offset..])?;

    let frequency_mhz = radiotap.frequency_mhz.unwrap_or_default();
    let channel = frequency_mhz_to_channel(frequency_mhz);
    let snr_db = radiotap
        .rssi_dbm
        .zip(radiotap.noise_floor_dbm)
        .map(|(signal, noise)| signal - noise);

    Ok(SidekickObservation {
        sidekick_id: sidekick_id.to_string(),
        radio_id: radio_id.to_string(),
        interface_name: interface_name.to_string(),
        bssid: management.bssid,
        ssid: management.ssid,
        hidden_ssid: management.hidden_ssid,
        frame_type: management.frame_type,
        rssi_dbm: radiotap.rssi_dbm,
        noise_floor_dbm: radiotap.noise_floor_dbm,
        snr_db,
        frequency_mhz,
        channel,
        channel_width_mhz: None,
        captured_at_unix_nanos,
        captured_at_monotonic_nanos,
        parser_confidence: 0.9,
    })
}

fn radiotap_field_layout(field_index: u8) -> Option<(usize, usize)> {
    match field_index {
        0 => Some((8, 8)),  // TSFT
        1 => Some((1, 1)),  // flags
        2 => Some((1, 1)),  // rate
        3 => Some((2, 4)),  // channel
        4 => Some((2, 2)),  // FHSS
        5 => Some((1, 1)),  // antenna signal
        6 => Some((1, 1)),  // antenna noise
        7 => Some((2, 2)),  // lock quality
        8 => Some((2, 2)),  // tx attenuation
        9 => Some((2, 2)),  // db tx attenuation
        10 => Some((1, 1)), // dbm tx power
        11 => Some((1, 1)), // antenna
        12 => Some((1, 1)), // db antenna signal
        13 => Some((1, 1)), // db antenna noise
        14 => Some((2, 2)), // rx flags
        _ => None,
    }
}

fn align_cursor(cursor: usize, align: usize) -> usize {
    if align <= 1 {
        cursor
    } else {
        (cursor + align - 1) & !(align - 1)
    }
}

fn parse_ssid_ie(ies: &[u8]) -> Option<String> {
    let mut cursor = 0;
    while cursor + 2 <= ies.len() {
        let element_id = ies[cursor];
        let len = ies[cursor + 1] as usize;
        cursor += 2;
        if cursor + len > ies.len() {
            return None;
        }

        if element_id == 0 {
            let ssid = &ies[cursor..cursor + len];
            if ssid.is_empty() || ssid.iter().all(|byte| *byte == 0) {
                return Some(String::new());
            }

            return Some(String::from_utf8_lossy(ssid).to_string());
        }

        cursor += len;
    }

    None
}

fn mac_to_string(raw: &[u8]) -> String {
    raw.iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<Vec<_>>()
        .join(":")
}

fn frequency_mhz_to_channel(frequency_mhz: u32) -> Option<u16> {
    match frequency_mhz {
        2_412..=2_472 => Some(((frequency_mhz - 2_407) / 5) as u16),
        2_484 => Some(14),
        5_000..=5_895 => Some(((frequency_mhz - 5_000) / 5) as u16),
        5_955..=7_115 => Some(((frequency_mhz - 5_950) / 5) as u16),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_radiotap_signal_noise_and_channel() {
        let packet = [
            0x00, 0x00, 0x0e, 0x00, // radiotap version, pad, length
            0x68, 0x00, 0x00, 0x00, // present: channel, signal, noise
            0x6c, 0x09, 0xa0, 0x00, // channel 2412, flags
            0xc7, 0xa1, // -57 signal, -95 noise
            0x80, 0x00, // beacon frame starts
        ];

        let parsed = parse_radiotap(&packet).unwrap();

        assert_eq!(parsed.payload_offset, 14);
        assert_eq!(parsed.frequency_mhz, Some(2_412));
        assert_eq!(parsed.rssi_dbm, Some(-57));
        assert_eq!(parsed.noise_floor_dbm, Some(-95));
    }

    #[test]
    fn parses_beacon_bssid_and_ssid() {
        let mut frame = Vec::new();
        frame.extend_from_slice(&[0x80, 0x00]); // beacon
        frame.extend_from_slice(&[0x00, 0x00]); // duration
        frame.extend_from_slice(&[0xff; 6]); // receiver
        frame.extend_from_slice(&[0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]); // transmitter
        frame.extend_from_slice(&[0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]); // bssid
        frame.extend_from_slice(&[0x10, 0x00]); // seq
        frame.extend_from_slice(&[0; 8]); // timestamp
        frame.extend_from_slice(&[0x64, 0x00]); // interval
        frame.extend_from_slice(&[0x31, 0x04]); // capabilities
        frame.extend_from_slice(&[0x00, 0x08]); // SSID IE
        frame.extend_from_slice(b"fieldlab");

        let parsed = parse_management_frame(&frame).unwrap();

        assert_eq!(parsed.frame_type, ManagementFrameType::Beacon);
        assert_eq!(parsed.bssid, "aa:bb:cc:dd:ee:ff");
        assert_eq!(parsed.ssid.as_deref(), Some("fieldlab"));
        assert!(!parsed.hidden_ssid);
    }

    #[test]
    fn builds_observation_from_radiotap_packet() {
        let mut packet = Vec::new();
        packet.extend_from_slice(&[
            0x00, 0x00, 0x0e, 0x00, // radiotap header
            0x68, 0x00, 0x00, 0x00, // present: channel, signal, noise
            0x3c, 0x14, 0xa0, 0x00, // channel 5180
            0xc0, 0x9f, // -64 signal, -97 noise
        ]);
        packet.extend_from_slice(&[0x80, 0x00, 0x00, 0x00]);
        packet.extend_from_slice(&[0xff; 6]);
        packet.extend_from_slice(&[0x00, 0x11, 0x22, 0x33, 0x44, 0x55]);
        packet.extend_from_slice(&[0x00, 0x11, 0x22, 0x33, 0x44, 0x55]);
        packet.extend_from_slice(&[0x10, 0x00]);
        packet.extend_from_slice(&[0; 8]);
        packet.extend_from_slice(&[0x64, 0x00, 0x31, 0x04]);
        packet.extend_from_slice(&[0x00, 0x08]);
        packet.extend_from_slice(b"sidekick");

        let observation =
            observation_from_packet(&packet, "sidekick-1", "radio-1", "wlan2", 1234, Some(5678))
                .unwrap();

        assert_eq!(observation.bssid, "00:11:22:33:44:55");
        assert_eq!(observation.ssid.as_deref(), Some("sidekick"));
        assert_eq!(observation.frequency_mhz, 5_180);
        assert_eq!(observation.channel, Some(36));
        assert_eq!(observation.rssi_dbm, Some(-64));
        assert_eq!(observation.snr_db, Some(33));
        assert_eq!(observation.captured_at_unix_nanos, 1234);
        assert_eq!(observation.captured_at_monotonic_nanos, Some(5678));
    }
}
