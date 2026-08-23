//! mDNS/DNS-SD decoding for passive device identification.
//!
//! The passive census (`census.rs`) answers "what is on this segment" with a MAC
//! and an address. It cannot answer "what IS it": an OUI names whoever registered
//! the NIC's address block, so every iPhone, iPad, Mac, Apple TV and HomePod is
//! "Apple, Inc.".
//!
//! mDNS answers that. A device advertising `_airplay._tcp` with a TXT `model=B620AP`
//! has told the segment it is a HomePod mini. Observed on a live segment, alongside
//! `_hue._tcp` + `_hap._tcp` for a Philips Hue bridge and `_nvstream_dbd._tcp` for a
//! GameStream host -- all of which OUI alone could only call "Apple", "Philips
//! Lighting" and "ASUSTek".
//!
//! # Scope of this module
//!
//! Pure decoding. Bytes in, normalized evidence out: no kernel, no sockets, no
//! clock, no allocation limits beyond what the DNS format itself imposes. That is
//! what makes the adversarial cases below testable at all -- name compression
//! loops and truncation are decided here, not in an integration test against a
//! live network.
//!
//! # This is evidence, not identity
//!
//! Nothing here may create or merge a device. mDNS instance names are user-chosen
//! ("Mike's iPhone") and services are shared between products, so it is a WEAK
//! signal that enriches a device the census already bound to a MAC.

use std::collections::BTreeMap;

/// Hard ceiling on compression-pointer hops.
///
/// A DNS name may point at an earlier name, which may itself point earlier again.
/// Without a budget a crafted packet loops forever inside the parser. Eight is far
/// more than any real encoder emits and bounds the work regardless of input.
const MAX_NAME_JUMPS: usize = 8;

/// RFC 1035 limits: 63 bytes per label, 255 bytes per name.
const MAX_LABEL_LEN: usize = 63;
const MAX_NAME_LEN: usize = 255;

const DNS_HEADER_LEN: usize = 12;

/// mDNS overloads the top bit of the class field: on a question it means "unicast
/// response requested", on a record it means "cache flush" (RFC 6762 §10.2, §18.12).
///
/// This is the single most common way DNS code silently fails on mDNS -- a parser
/// that compares `rclass == IN` drops every announcement, because announcements are
/// exactly the records that set this bit.
const CLASS_FLUSH_MASK: u16 = 0x8000;

pub const TYPE_A: u16 = 1;
pub const TYPE_PTR: u16 = 12;
pub const TYPE_TXT: u16 = 16;
pub const TYPE_AAAA: u16 = 28;
pub const TYPE_SRV: u16 = 33;

/// TXT keys worth recording, and nothing else.
///
/// TXT is free-form: devices put serial numbers, auth tokens, pairing state and
/// user-chosen names in there. `dpi.rs` already carries an explicit decision that
/// user content does not leave the process (`does_not_emit_uri_or_dns_names`), and
/// capturing arbitrary TXT would quietly cross that line while calling it device
/// identification.
///
/// So this is a CLOSED allowlist of keys that name a product:
///   `md`       Google Cast model, e.g. "Chromecast Ultra"
///   `model`    Apple model identifier, e.g. "B620AP" (HomePod mini)
///   `am`       AirPlay model, e.g. "AudioAccessory5,1"
///   `ty`       printer description, e.g. "HP LaserJet"
///   `usb_MDL`  printer model
///   `usb_MFG`  printer manufacturer
///   `manufacturer` / `vendor`  occasionally present verbatim
///
/// Adding a key here widens what is collected from every device on the segment.
/// It is a deliberate act, not a convenience.
pub const TXT_KEY_ALLOWLIST: &[&str] = &[
    "md",
    "model",
    "am",
    "ty",
    "usb_MDL",
    "usb_MFG",
    "manufacturer",
    "vendor",
];

/// One decoded resource record, narrowed to what identification needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MdnsRecord {
    /// A service instance: `_airplay._tcp.local` -> `Living Room._airplay._tcp.local`
    Ptr { name: String, target: String },
    /// Where the service runs. The port is kept; the target host is a hostname the
    /// user chose, so it is recorded but never treated as identity.
    Srv {
        name: String,
        target: String,
        port: u16,
    },
    /// Allowlisted TXT keys only. A key present with no value is `None`, which RFC
    /// 6763 §6.4 defines as "attribute present, boolean true" -- distinct from a
    /// key whose value is the empty string.
    Txt {
        name: String,
        pairs: BTreeMap<String, Option<String>>,
    },
}

/// Normalized mDNS evidence from one packet.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MdnsObservation {
    pub records: Vec<MdnsRecord>,
    /// Service types seen, e.g. `_airplay._tcp`. Deduplicated and sorted so a
    /// snapshot of the same device is byte-stable across packets.
    pub service_types: Vec<String>,
    /// Allowlisted TXT pairs merged across records, for the common case where a
    /// caller wants "what model is this" without walking records.
    pub txt: BTreeMap<String, Option<String>>,
    /// The DNS header's truncation bit. A truncated announcement may be missing the
    /// TXT record that carries the model, so a caller can choose to wait rather
    /// than conclude.
    pub truncated: bool,
}

impl MdnsObservation {
    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }
}

/// Read a (possibly compressed) DNS name.
///
/// Returns the decoded name and the offset immediately AFTER the name *in the
/// original stream* -- which for a compressed name is two bytes past its start,
/// not past the data it points at. Getting that wrong walks the parser into the
/// middle of a record.
///
/// Rejects, rather than tolerates:
///   - a pointer whose target is not strictly earlier than the pointer itself
///     (the only way to guarantee termination without trusting a counter)
///   - more than `MAX_NAME_JUMPS` hops
///   - labels over 63 bytes or a total name over 255
///   - the reserved `0x40` / `0x80` label prefixes
pub fn read_dns_name(message: &[u8], start: usize) -> Option<(String, usize)> {
    let mut labels: Vec<String> = Vec::new();
    let mut total_len = 0usize;
    let mut jumps = 0usize;
    let mut offset = start;
    // Offset to report back to the caller: fixed at the first pointer we follow.
    let mut end_offset: Option<usize> = None;

    loop {
        let len_byte = *message.get(offset)?;

        match len_byte & 0xC0 {
            0x00 => {
                let len = usize::from(len_byte);
                offset = offset.checked_add(1)?;

                if len == 0 {
                    let end = end_offset.unwrap_or(offset);
                    return Some((labels.join("."), end));
                }

                if len > MAX_LABEL_LEN {
                    return None;
                }
                total_len = total_len.checked_add(len + 1)?;
                if total_len > MAX_NAME_LEN {
                    return None;
                }

                let raw = message.get(offset..offset.checked_add(len)?)?;
                // A label is not required to be UTF-8. Rejecting the whole name
                // over one odd byte would discard otherwise-usable evidence --
                // including the service type, which is the part that identifies
                // the device -- so decode lossily and keep going.
                labels.push(String::from_utf8_lossy(raw).into_owned());
                offset = offset.checked_add(len)?;
            }
            0xC0 => {
                let second = *message.get(offset.checked_add(1)?)?;
                let target = usize::from(u16::from_be_bytes([len_byte & 0x3F, second]));

                // STRICTLY earlier. A pointer to itself or forward is what turns a
                // parser into an infinite loop, and a jump budget alone only bounds
                // the damage rather than preventing it.
                if target >= offset {
                    return None;
                }

                jumps = jumps.checked_add(1)?;
                if jumps > MAX_NAME_JUMPS {
                    return None;
                }

                if end_offset.is_none() {
                    end_offset = Some(offset.checked_add(2)?);
                }
                offset = target;
            }
            // 0x40 and 0x80 are reserved label types (RFC 6891 retired the only
            // ever-defined one). Treat as malformed rather than guessing.
            _ => return None,
        }
    }
}

/// Parse an mDNS message into normalized evidence.
///
/// Returns `None` only when the message cannot be a DNS message at all. A record
/// that is individually malformed is skipped while its siblings survive: a single
/// bad TXT should not discard the PTR that names the service.
pub fn parse_mdns_payload(payload: &[u8]) -> Option<MdnsObservation> {
    if payload.len() < DNS_HEADER_LEN {
        return None;
    }

    let flags = u16::from_be_bytes([payload[2], payload[3]]);
    let qdcount = u16::from_be_bytes([payload[4], payload[5]]) as usize;
    let ancount = u16::from_be_bytes([payload[6], payload[7]]) as usize;
    let nscount = u16::from_be_bytes([payload[8], payload[9]]) as usize;
    let arcount = u16::from_be_bytes([payload[10], payload[11]]) as usize;

    let mut observation = MdnsObservation {
        truncated: flags & 0x0200 != 0,
        ..Default::default()
    };

    let mut offset = DNS_HEADER_LEN;

    // Questions carry no answers, but they must be walked to reach the records.
    // The counts are attacker-controlled, so every step is bounds-checked and the
    // walk stops at the first inconsistency rather than trusting the header.
    for _ in 0..qdcount {
        let (_name, next) = read_dns_name(payload, offset)?;
        offset = next.checked_add(4)?;
        if offset > payload.len() {
            return None;
        }
    }

    let record_count = ancount.saturating_add(nscount).saturating_add(arcount);
    for _ in 0..record_count {
        let Some((name, next)) = read_dns_name(payload, offset) else {
            break;
        };
        let Some(header) = payload.get(next..next.checked_add(10)?) else {
            break;
        };
        let rtype = u16::from_be_bytes([header[0], header[1]]);
        // Strip the cache-flush bit before the class is used for anything.
        let _rclass = u16::from_be_bytes([header[2], header[3]]) & !CLASS_FLUSH_MASK;
        let rdlength = usize::from(u16::from_be_bytes([header[8], header[9]]));

        let rdata_start = next.checked_add(10)?;
        let rdata_end = rdata_start.checked_add(rdlength)?;
        let Some(rdata) = payload.get(rdata_start..rdata_end) else {
            // rdlength claims more than the message holds. Everything after this
            // point is unparseable, so stop rather than guess a resync.
            break;
        };

        match rtype {
            TYPE_PTR => {
                if let Some((target, _)) = read_dns_name(payload, rdata_start) {
                    if let Some(service) = service_type_of(&name) {
                        push_unique(&mut observation.service_types, service);
                    }
                    observation.records.push(MdnsRecord::Ptr { name, target });
                }
            }
            TYPE_SRV => {
                if rdata.len() >= 6 {
                    let port = u16::from_be_bytes([rdata[4], rdata[5]]);
                    if let Some((target, _)) = read_dns_name(payload, rdata_start + 6) {
                        if let Some(service) = service_type_of(&name) {
                            push_unique(&mut observation.service_types, service);
                        }
                        observation
                            .records
                            .push(MdnsRecord::Srv { name, target, port });
                    }
                }
            }
            TYPE_TXT => {
                let pairs = parse_txt(rdata);
                if !pairs.is_empty() {
                    for (key, value) in &pairs {
                        observation.txt.insert(key.clone(), value.clone());
                    }
                    observation.records.push(MdnsRecord::Txt { name, pairs });
                }
            }
            _ => {}
        }

        offset = rdata_end;
    }

    observation.service_types.sort();

    if observation.is_empty() && observation.txt.is_empty() {
        None
    } else {
        Some(observation)
    }
}

/// Extract `_airplay._tcp` from `Living Room._airplay._tcp.local`.
///
/// Returns None for a name that is not a DNS-SD service instance, so a plain
/// hostname announcement does not masquerade as a service type.
fn service_type_of(name: &str) -> Option<String> {
    let labels: Vec<&str> = name.split('.').collect();
    let position = labels
        .iter()
        .position(|label| label.starts_with('_') && *label != "_udp" && *label != "_tcp")?;
    let proto = labels.get(position + 1)?;
    if *proto != "_tcp" && *proto != "_udp" {
        return None;
    }
    Some(format!("{}.{}", labels[position], proto))
}

/// Parse TXT rdata: a sequence of length-prefixed strings, each `key` or `key=value`.
///
/// Only allowlisted keys survive. Three cases that are genuinely different and are
/// kept different:
///   `key`      -> `None`         attribute present, no value (RFC 6763 §6.4)
///   `key=`     -> `Some("")`     attribute present, value empty
///   `=value`   -> discarded      empty key is malformed
fn parse_txt(rdata: &[u8]) -> BTreeMap<String, Option<String>> {
    let mut pairs = BTreeMap::new();
    let mut offset = 0usize;

    while offset < rdata.len() {
        let len = usize::from(rdata[offset]);
        offset += 1;
        if len == 0 {
            continue;
        }
        let Some(entry) = rdata.get(offset..offset + len) else {
            // One string overruns the record. Stop; earlier pairs stand.
            break;
        };
        offset += len;

        let (key, value) = match entry.iter().position(|byte| *byte == b'=') {
            Some(0) => continue,
            Some(index) => (
                &entry[..index],
                Some(String::from_utf8_lossy(&entry[index + 1..]).into_owned()),
            ),
            None => (entry, None),
        };

        let Ok(key) = std::str::from_utf8(key) else {
            continue;
        };
        if TXT_KEY_ALLOWLIST.contains(&key) {
            pairs.insert(key.to_owned(), value);
        }
    }

    pairs
}

fn push_unique(values: &mut Vec<String>, value: String) {
    if !values.contains(&value) {
        values.push(value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a DNS name as wire labels terminated by a root byte.
    fn labels(name: &str) -> Vec<u8> {
        let mut out = Vec::new();
        for label in name.split('.') {
            out.push(label.len() as u8);
            out.extend_from_slice(label.as_bytes());
        }
        out.push(0);
        out
    }

    fn header(qd: u16, an: u16, flags: u16) -> Vec<u8> {
        let mut out = vec![0x00, 0x00];
        out.extend_from_slice(&flags.to_be_bytes());
        out.extend_from_slice(&qd.to_be_bytes());
        out.extend_from_slice(&an.to_be_bytes());
        out.extend_from_slice(&0u16.to_be_bytes());
        out.extend_from_slice(&0u16.to_be_bytes());
        out
    }

    /// One answer record. `class_flush` sets the mDNS cache-flush bit, which real
    /// announcements always do.
    fn record(name: &[u8], rtype: u16, rdata: &[u8], class_flush: bool) -> Vec<u8> {
        let mut out = name.to_vec();
        out.extend_from_slice(&rtype.to_be_bytes());
        let class = if class_flush { 0x8001u16 } else { 0x0001u16 };
        out.extend_from_slice(&class.to_be_bytes());
        out.extend_from_slice(&120u32.to_be_bytes());
        out.extend_from_slice(&(rdata.len() as u16).to_be_bytes());
        out.extend_from_slice(rdata);
        out
    }

    fn txt_rdata(entries: &[&str]) -> Vec<u8> {
        let mut out = Vec::new();
        for entry in entries {
            out.push(entry.len() as u8);
            out.extend_from_slice(entry.as_bytes());
        }
        out
    }

    // ---- name compression -------------------------------------------------

    #[test]
    fn resolves_a_backward_compression_pointer() {
        let mut msg = header(0, 0, 0);
        let base = msg.len();
        msg.extend_from_slice(&labels("_airplay._tcp.local"));
        let pointer_at = msg.len();
        msg.push(0xC0 | ((base >> 8) as u8));
        msg.push(base as u8);

        let (name, end) = read_dns_name(&msg, pointer_at).expect("pointer resolves");
        assert_eq!(name, "_airplay._tcp.local");
        assert_eq!(
            end,
            pointer_at + 2,
            "end offset is past the POINTER, not its target"
        );
    }

    #[test]
    fn resolves_a_multi_hop_chain_within_budget() {
        // "local" <- "_tcp" + ptr <- "_airplay" + ptr
        let mut msg = header(0, 0, 0);
        let local_at = msg.len();
        msg.extend_from_slice(&labels("local"));

        let tcp_at = msg.len();
        msg.push(4);
        msg.extend_from_slice(b"_tcp");
        msg.push(0xC0);
        msg.push(local_at as u8);

        let air_at = msg.len();
        msg.push(8);
        msg.extend_from_slice(b"_airplay");
        msg.push(0xC0);
        msg.push(tcp_at as u8);

        let (name, _) = read_dns_name(&msg, air_at).expect("chain resolves");
        assert_eq!(name, "_airplay._tcp.local");
    }

    #[test]
    fn a_self_referencing_pointer_terminates() {
        // The classic hang. Must return, not loop.
        let mut msg = header(0, 0, 0);
        let at = msg.len();
        msg.push(0xC0 | ((at >> 8) as u8));
        msg.push(at as u8);

        assert_eq!(read_dns_name(&msg, at), None);
    }

    #[test]
    fn two_mutually_referencing_pointers_terminate() {
        let mut msg = header(0, 0, 0);
        let a = msg.len();
        msg.push(0xC0);
        msg.push((a + 2) as u8);
        let b = msg.len();
        msg.push(0xC0);
        msg.push(a as u8);

        // Whichever end we enter from, the strictly-backward rule stops it.
        assert_eq!(read_dns_name(&msg, a), None);
        assert_eq!(read_dns_name(&msg, b), None);
    }

    #[test]
    fn a_forward_or_self_pointer_is_refused() {
        let mut msg = header(0, 0, 0);
        let at = msg.len();
        msg.push(0xC0);
        msg.push((at + 8) as u8); // forward
        msg.extend_from_slice(&labels("local"));

        assert_eq!(read_dns_name(&msg, at), None);
    }

    #[test]
    fn a_pointer_past_the_end_is_refused() {
        let mut msg = header(0, 0, 0);
        let at = msg.len();
        msg.push(0xC0);
        msg.push(0xFE);
        assert_eq!(read_dns_name(&msg, at), None);
    }

    #[test]
    fn reserved_label_prefixes_are_refused() {
        for prefix in [0x40u8, 0x80u8] {
            let mut msg = header(0, 0, 0);
            let at = msg.len();
            msg.push(prefix | 0x05);
            msg.extend_from_slice(b"local");
            msg.push(0);
            assert_eq!(
                read_dns_name(&msg, at),
                None,
                "prefix {prefix:#x} must be refused"
            );
        }
    }

    #[test]
    fn label_length_boundary() {
        let ok = "a".repeat(MAX_LABEL_LEN);
        let mut msg = header(0, 0, 0);
        let at = msg.len();
        msg.push(MAX_LABEL_LEN as u8);
        msg.extend_from_slice(ok.as_bytes());
        msg.push(0);
        assert!(read_dns_name(&msg, at).is_some(), "63 is legal");

        // 64 sets 0x40, which is a reserved prefix -- refused either way.
        let mut msg = header(0, 0, 0);
        let at = msg.len();
        msg.push(64);
        msg.extend_from_slice(&[b'a'; 64]);
        msg.push(0);
        assert_eq!(read_dns_name(&msg, at), None, "64 is not legal");
    }

    #[test]
    fn a_name_over_255_bytes_is_refused() {
        let mut msg = header(0, 0, 0);
        let at = msg.len();
        for _ in 0..8 {
            msg.push(50);
            msg.extend_from_slice(&[b'a'; 50]);
        }
        msg.push(0);
        assert_eq!(read_dns_name(&msg, at), None);
    }

    // ---- message parsing --------------------------------------------------

    fn announcement() -> Vec<u8> {
        let mut msg = header(0, 2, 0);
        msg.extend_from_slice(&record(
            &labels("Speaker._airplay._tcp.local"),
            TYPE_PTR,
            &labels("Speaker._airplay._tcp.local"),
            true,
        ));
        msg.extend_from_slice(&record(
            &labels("Speaker._airplay._tcp.local"),
            TYPE_TXT,
            &txt_rdata(&["model=B620AP", "am=AudioAccessory5,1", "deviceid=AA:BB:CC"]),
            true,
        ));
        msg
    }

    #[test]
    fn decodes_a_real_shaped_announcement() {
        let observation = parse_mdns_payload(&announcement()).expect("parses");

        assert_eq!(observation.service_types, vec!["_airplay._tcp"]);
        // The whole point: an OUI can only say "Apple, Inc." for this device.
        assert_eq!(
            observation.txt.get("model"),
            Some(&Some("B620AP".to_owned()))
        );
        assert_eq!(
            observation.txt.get("am"),
            Some(&Some("AudioAccessory5,1".to_owned()))
        );
    }

    #[test]
    fn the_cache_flush_bit_does_not_hide_records() {
        // Announcements set 0x8000 on the class. A parser comparing rclass == IN
        // drops exactly the records that matter, and does so silently.
        let flushed = parse_mdns_payload(&announcement()).expect("flushed parses");
        assert!(!flushed.records.is_empty());

        let mut plain = header(0, 1, 0);
        plain.extend_from_slice(&record(
            &labels("Speaker._airplay._tcp.local"),
            TYPE_TXT,
            &txt_rdata(&["model=B620AP"]),
            false,
        ));
        let plain = parse_mdns_payload(&plain).expect("unflushed parses");
        assert_eq!(plain.txt.get("model"), Some(&Some("B620AP".to_owned())));
    }

    #[test]
    fn a_truncated_prefix_never_panics() {
        // One loop that covers every slice-arithmetic mistake in the parser.
        let full = announcement();
        for n in 0..full.len() {
            let _ = parse_mdns_payload(&full[..n]);
        }
    }

    #[test]
    fn lying_counts_do_not_cause_unbounded_work() {
        let mut msg = header(0xFFFF, 0xFFFF, 0);
        msg.truncate(DNS_HEADER_LEN);
        assert_eq!(parse_mdns_payload(&msg), None);
    }

    #[test]
    fn an_rdlength_overrun_drops_that_record_not_the_earlier_ones() {
        let mut msg = header(0, 2, 0);
        msg.extend_from_slice(&record(
            &labels("Speaker._airplay._tcp.local"),
            TYPE_TXT,
            &txt_rdata(&["model=B620AP"]),
            true,
        ));
        // A second record claiming far more rdata than remains.
        let mut bad = labels("Speaker._airplay._tcp.local");
        bad.extend_from_slice(&TYPE_TXT.to_be_bytes());
        bad.extend_from_slice(&0x8001u16.to_be_bytes());
        bad.extend_from_slice(&120u32.to_be_bytes());
        bad.extend_from_slice(&9999u16.to_be_bytes());
        msg.extend_from_slice(&bad);

        let observation = parse_mdns_payload(&msg).expect("first record survives");
        assert_eq!(
            observation.txt.get("model"),
            Some(&Some("B620AP".to_owned()))
        );
    }

    // ---- TXT semantics ----------------------------------------------------

    #[test]
    fn txt_present_with_no_value_is_distinct_from_an_empty_value() {
        // RFC 6763 6.4: `key` means present/true; `key=` means present with an
        // empty value. Collapsing them loses a real distinction.
        let no_value = parse_txt(&txt_rdata(&["model"]));
        assert_eq!(no_value.get("model"), Some(&None));

        let empty_value = parse_txt(&txt_rdata(&["model="]));
        assert_eq!(empty_value.get("model"), Some(&Some(String::new())));

        assert_ne!(no_value, empty_value);
    }

    #[test]
    fn txt_with_an_empty_key_is_discarded() {
        assert!(parse_txt(&txt_rdata(&["=orphan"])).is_empty());
    }

    #[test]
    fn txt_keys_outside_the_allowlist_are_not_collected() {
        // Devices put serials, tokens and pairing state in TXT. Collecting all of
        // it would be data collection wearing identification's clothes.
        let pairs = parse_txt(&txt_rdata(&[
            "model=B620AP",
            "deviceid=AA:BB:CC:DD:EE:FF",
            "serialNumber=F2LX1234",
            "pk=3b9a7c0e",
        ]));

        assert_eq!(pairs.len(), 1);
        assert!(pairs.contains_key("model"));
        for leaked in ["deviceid", "serialNumber", "pk"] {
            assert!(
                !pairs.contains_key(leaked),
                "{leaked} must not be collected"
            );
        }
    }

    #[test]
    fn a_txt_string_overrunning_the_record_keeps_its_siblings() {
        let mut rdata = txt_rdata(&["model=B620AP"]);
        rdata.push(200); // claims 200 bytes that are not there
        rdata.extend_from_slice(b"short");

        let pairs = parse_txt(&rdata);
        assert_eq!(pairs.get("model"), Some(&Some("B620AP".to_owned())));
    }

    #[test]
    fn txt_values_survive_non_utf8_bytes() {
        let mut rdata = Vec::new();
        let entry = b"model=B6\xFF20AP";
        rdata.push(entry.len() as u8);
        rdata.extend_from_slice(entry);

        let pairs = parse_txt(&rdata);
        assert!(
            pairs.contains_key("model"),
            "a stray byte must not drop the key"
        );
    }

    // ---- table aggregation ------------------------------------------------

    const SEC: u64 = 1_000_000_000;
    const MAC_A: [u8; 6] = [0x48, 0xE1, 0x5C, 0xA8, 0x2B, 0x58];
    const MAC_B: [u8; 6] = [0xAC, 0xBC, 0xB5, 0xDC, 0x45, 0xE3];

    fn observation_of(services: &[&str], txt: &[(&str, &str)]) -> MdnsObservation {
        MdnsObservation {
            records: vec![MdnsRecord::Ptr {
                name: "x".into(),
                target: "y".into(),
            }],
            service_types: services.iter().map(|s| (*s).to_owned()).collect(),
            txt: txt
                .iter()
                .map(|(k, v)| ((*k).to_owned(), Some((*v).to_owned())))
                .collect(),
            truncated: false,
        }
    }

    fn table() -> MdnsTable {
        MdnsTable::new(std::time::Duration::from_secs(900), 4096)
    }

    #[test]
    fn a_device_is_described_across_several_packets() {
        // The reason the table exists: a device does not describe itself in one
        // packet. The PTR naming the service and the TXT carrying the model can
        // be minutes apart.
        let mut t = table();
        assert!(t.observe(2, MAC_A, &observation_of(&["_airplay._tcp"], &[]), SEC));
        assert!(!t.observe(
            2,
            MAC_A,
            &observation_of(&["_companion-link._tcp"], &[("model", "B620AP")]),
            2 * SEC
        ));

        let entry = &t.snapshot()[0];
        assert_eq!(
            entry.service_types,
            vec!["_airplay._tcp", "_companion-link._tcp"]
        );
        assert_eq!(entry.models, vec!["B620AP"]);
        assert_eq!(entry.first_seen_ns, SEC, "first sighting is preserved");
        assert_eq!(entry.last_seen_ns, 2 * SEC);
    }

    #[test]
    fn two_models_from_one_mac_are_kept_and_flagged_ambiguous() {
        // OBSERVED ON A LIVE SEGMENT: one MAC advertised both B620AP (HomePod
        // mini) and J255AP (Apple TV) because HomeKit relays announcements for
        // paired accessories. Last-write-wins would make the type flap forever;
        // picking the first would be arbitrary. Keep both and refuse to guess.
        let mut t = table();
        t.observe(2, MAC_A, &observation_of(&[], &[("model", "B620AP")]), SEC);
        t.observe(
            2,
            MAC_A,
            &observation_of(&[], &[("model", "J255AP")]),
            2 * SEC,
        );

        let entry = &t.snapshot()[0];
        assert_eq!(entry.models, vec!["B620AP", "J255AP"]);
        assert!(
            entry.ambiguous_model(),
            "core must not assign a type from this"
        );
    }

    #[test]
    fn a_single_model_is_not_ambiguous_however_often_repeated() {
        let mut t = table();
        for i in 1..5 {
            t.observe(
                2,
                MAC_A,
                &observation_of(&[], &[("model", "B620AP")]),
                i * SEC,
            );
        }
        let entry = &t.snapshot()[0];
        assert_eq!(entry.models, vec!["B620AP"]);
        assert!(!entry.ambiguous_model());
    }

    #[test]
    fn md_is_used_when_model_is_absent() {
        // Google Cast uses `md`; Apple uses `model`. Both name the product.
        let mut t = table();
        t.observe(
            2,
            MAC_A,
            &observation_of(&[], &[("md", "Chromecast Ultra")]),
            SEC,
        );
        assert_eq!(t.snapshot()[0].models, vec!["Chromecast Ultra"]);
    }

    #[test]
    fn distinct_macs_are_distinct_devices() {
        let mut t = table();
        t.observe(2, MAC_A, &observation_of(&["_airplay._tcp"], &[]), SEC);
        t.observe(2, MAC_B, &observation_of(&["_hap._tcp"], &[]), SEC);
        assert_eq!(t.len(), 2);
    }

    #[test]
    fn the_same_mac_on_two_interfaces_is_two_entries() {
        let mut t = table();
        t.observe(2, MAC_A, &observation_of(&["_airplay._tcp"], &[]), SEC);
        t.observe(3, MAC_A, &observation_of(&["_airplay._tcp"], &[]), SEC);
        assert_eq!(t.len(), 2, "a segment is scoped by interface");
    }

    #[test]
    fn expired_entries_are_evicted_so_absence_means_something() {
        let mut t = MdnsTable::new(std::time::Duration::from_secs(10), 4096);
        t.observe(2, MAC_A, &observation_of(&["_airplay._tcp"], &[]), SEC);
        assert_eq!(t.evict_expired(5 * SEC), 0, "still fresh");
        assert_eq!(t.evict_expired(20 * SEC), 1, "past the ttl");
        assert!(t.is_empty());
    }

    #[test]
    fn the_table_is_bounded_and_evicts_the_coldest() {
        let mut t = MdnsTable::new(std::time::Duration::from_secs(900), 2);
        t.observe(
            2,
            [0, 0, 0, 0, 0, 1],
            &observation_of(&["_a._tcp"], &[]),
            SEC,
        );
        t.observe(
            2,
            [0, 0, 0, 0, 0, 2],
            &observation_of(&["_b._tcp"], &[]),
            5 * SEC,
        );
        t.observe(
            2,
            [0, 0, 0, 0, 0, 3],
            &observation_of(&["_c._tcp"], &[]),
            9 * SEC,
        );

        assert_eq!(t.len(), 2);
        let macs: Vec<[u8; 6]> = t.snapshot().iter().map(|e| e.mac).collect();
        assert!(!macs.contains(&[0, 0, 0, 0, 0, 1]), "coldest is evicted");
    }

    #[test]
    fn a_snapshot_is_deterministic() {
        let mut t = table();
        t.observe(2, MAC_B, &observation_of(&["_z._tcp", "_a._tcp"], &[]), SEC);
        t.observe(2, MAC_A, &observation_of(&["_m._tcp"], &[]), SEC);

        let first = t.snapshot();
        let second = t.snapshot();
        assert_eq!(first, second, "same table must snapshot identically");
        assert!(first[0].mac < first[1].mac, "ordered by mac");
        assert_eq!(
            first[1].service_types,
            vec!["_a._tcp", "_z._tcp"],
            "service types sorted, not insertion-ordered"
        );
    }

    // ---- service type extraction -----------------------------------------

    #[test]
    fn extracts_the_service_type_from_an_instance_name() {
        assert_eq!(
            service_type_of("Living Room._airplay._tcp.local"),
            Some("_airplay._tcp".to_owned())
        );
        assert_eq!(
            service_type_of("_googlecast._tcp.local"),
            Some("_googlecast._tcp".to_owned())
        );
    }

    #[test]
    fn a_plain_hostname_is_not_a_service_type() {
        assert_eq!(service_type_of("Philips-hue2.local"), None);
        assert_eq!(service_type_of("local"), None);
        assert_eq!(service_type_of(""), None);
    }
}

/// What one device on the segment has told us about itself.
///
/// Keyed by MAC, because that is the identity the census already bound. mDNS
/// enriches a device that is already known; it never mints one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MdnsEntry {
    pub interface_index: u32,
    pub mac: [u8; 6],
    /// Sorted and deduplicated, so a snapshot of an unchanged device is
    /// byte-identical between runs.
    pub service_types: Vec<String>,
    pub txt: BTreeMap<String, Option<String>>,
    /// Every distinct model string seen from this MAC, sorted.
    ///
    /// Deliberately a set rather than last-write-wins. Observed on a live
    /// segment: one MAC advertised BOTH `B620AP` (HomePod mini) and `J255AP`
    /// (Apple TV) because HomeKit relays announcements for paired accessories.
    /// Overwriting would make the device's type flap between the two forever,
    /// and picking the first would be arbitrary.
    pub models: Vec<String>,
    pub first_seen_ns: u64,
    pub last_seen_ns: u64,
}

impl MdnsEntry {
    /// True when this MAC has claimed more than one model.
    ///
    /// Core must not assign a device type from an ambiguous entry: the evidence
    /// says "this MAC speaks for two products", not "this device is one of
    /// them". Better to leave the type unset than to pick.
    pub fn ambiguous_model(&self) -> bool {
        self.models.len() > 1
    }
}

/// Accumulates mDNS evidence per device, with the same bounds as `CensusTable`.
///
/// A device does not describe itself in one packet: it announces different
/// services at different times, and the TXT carrying the model may arrive
/// minutes after the PTR naming the service. Accumulating is what turns a
/// stream of partial announcements into a usable answer.
#[derive(Debug)]
pub struct MdnsTable {
    ttl: std::time::Duration,
    capacity: usize,
    entries: std::collections::HashMap<(u32, [u8; 6]), MdnsEntry>,
}

impl MdnsTable {
    pub fn new(ttl: std::time::Duration, capacity: usize) -> Self {
        Self {
            ttl,
            capacity,
            entries: std::collections::HashMap::new(),
        }
    }

    /// Fold one packet's evidence into the table. Returns true when this MAC
    /// was not already known.
    pub fn observe(
        &mut self,
        interface_index: u32,
        mac: [u8; 6],
        observation: &MdnsObservation,
        observed_ns: u64,
    ) -> bool {
        let key = (interface_index, mac);
        let model = observation
            .txt
            .get("model")
            .or_else(|| observation.txt.get("md"))
            .and_then(|value| value.clone());

        if let Some(entry) = self.entries.get_mut(&key) {
            entry.last_seen_ns = observed_ns;
            merge_sorted(&mut entry.service_types, &observation.service_types);
            for (k, v) in &observation.txt {
                entry.txt.insert(k.clone(), v.clone());
            }
            if let Some(model) = model {
                merge_sorted(&mut entry.models, std::slice::from_ref(&model));
            }
            return false;
        }

        if self.entries.len() >= self.capacity {
            // Evict the coldest rather than grow without bound. mDNS is
            // announce-driven and a segment can be far larger than budgeted.
            if let Some(coldest) = self
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.last_seen_ns)
                .map(|(k, _)| *k)
            {
                self.entries.remove(&coldest);
            }
        }

        let mut service_types = observation.service_types.clone();
        service_types.sort();
        service_types.dedup();

        self.entries.insert(
            key,
            MdnsEntry {
                interface_index,
                mac,
                service_types,
                txt: observation.txt.clone(),
                models: model.into_iter().collect(),
                first_seen_ns: observed_ns,
                last_seen_ns: observed_ns,
            },
        );
        true
    }

    /// Drop entries not seen within the TTL. Returns how many were evicted.
    pub fn evict_expired(&mut self, monotonic_now_ns: u64) -> usize {
        let ttl_ns = self.ttl.as_nanos() as u64;
        let before = self.entries.len();
        self.entries
            .retain(|_, entry| monotonic_now_ns.saturating_sub(entry.last_seen_ns) < ttl_ns);
        before - self.entries.len()
    }

    /// The complete current view, ordered so a snapshot is deterministic.
    pub fn snapshot(&self) -> Vec<MdnsEntry> {
        let mut out: Vec<MdnsEntry> = self.entries.values().cloned().collect();
        out.sort_by_key(|entry| (entry.interface_index, entry.mac));
        out
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

fn merge_sorted(target: &mut Vec<String>, incoming: &[String]) {
    for value in incoming {
        if !target.contains(value) {
            target.push(value.clone());
        }
    }
    target.sort();
}
