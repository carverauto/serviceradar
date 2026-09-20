/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! V1 downparser for invented IOS-like device configs.
//!
//! Extracts per-interface name, IPv4/IPv6 prefix, description, VLAN, shutdown,
//! and VRF. Parser output is inventory facts, not the topology graph. Live
//! Network Automation dumps must not be used as fixtures.

/// Parser version written onto `network_config_revisions.parser_version`.
pub const PARSER_VERSION: &str = "network_config_v1";

/// One interface stanza extracted from a revision body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterfaceFact {
    pub if_name: String,
    pub ipv4_prefix: Option<String>,
    pub ipv6_prefix: Option<String>,
    pub vlan: Option<i32>,
    pub description: Option<String>,
    pub shutdown: bool,
    pub vrf: Option<String>,
}

/// Parse an invented IOS-like running-config body into interface facts.
#[must_use]
pub fn parse(body: &str) -> Vec<InterfaceFact> {
    let mut facts = Vec::new();
    let mut current: Option<Stanza> = None;

    for raw in body.lines() {
        let line = raw.trim_end();
        if let Some(name) = interface_header(line) {
            flush(&mut facts, current.take());
            if !name.is_empty() {
                current = Some(Stanza::new(name));
            }
            continue;
        }

        let in_stanza = current.is_some();
        let indented = line.starts_with(' ') || line.starts_with('\t');
        let trimmed = line.trim();

        if in_stanza && (indented || trimmed.is_empty() || trimmed == "!") {
            if let Some(stanza) = current.as_mut() {
                apply_command(stanza, trimmed);
            }
            continue;
        }

        if in_stanza && !indented && !trimmed.is_empty() && trimmed != "!" {
            flush(&mut facts, current.take());
        }
    }

    flush(&mut facts, current.take());
    facts
}

struct Stanza {
    if_name: String,
    ipv4_prefix: Option<String>,
    ipv6_prefix: Option<String>,
    vlan: Option<i32>,
    description: Option<String>,
    shutdown: bool,
    vrf: Option<String>,
}

impl Stanza {
    fn new(if_name: String) -> Self {
        Self {
            if_name,
            ipv4_prefix: None,
            ipv6_prefix: None,
            vlan: None,
            description: None,
            shutdown: false,
            vrf: None,
        }
    }

    fn into_fact(self) -> InterfaceFact {
        InterfaceFact {
            if_name: self.if_name,
            ipv4_prefix: self.ipv4_prefix,
            ipv6_prefix: self.ipv6_prefix,
            vlan: self.vlan,
            description: self.description,
            shutdown: self.shutdown,
            vrf: self.vrf,
        }
    }
}

fn flush(facts: &mut Vec<InterfaceFact>, stanza: Option<Stanza>) {
    if let Some(stanza) = stanza {
        facts.push(stanza.into_fact());
    }
}

fn interface_header(line: &str) -> Option<String> {
    let name = strip_ignore_case(line.trim(), "interface ")?.trim();
    if name.is_empty() || strip_ignore_case(name, "range ").is_some() {
        return None;
    }
    Some(name.to_string())
}

fn apply_command(stanza: &mut Stanza, cmd: &str) {
    if cmd.is_empty() || cmd == "!" {
        return;
    }
    if cmd.eq_ignore_ascii_case("shutdown") {
        stanza.shutdown = true;
        return;
    }
    if cmd.eq_ignore_ascii_case("no shutdown") {
        stanza.shutdown = false;
        return;
    }
    if let Some(rest) = strip_ignore_case(cmd, "description ") {
        let desc = rest.trim();
        if !desc.is_empty() {
            stanza.description = Some(desc.to_string());
        }
        return;
    }
    if let Some(rest) = strip_ignore_case(cmd, "ip vrf forwarding ") {
        let vrf = rest.trim();
        if !vrf.is_empty() {
            stanza.vrf = Some(vrf.to_string());
        }
        return;
    }
    if let Some(rest) = strip_ignore_case(cmd, "vrf forwarding ") {
        let vrf = rest.trim();
        if !vrf.is_empty() {
            stanza.vrf = Some(vrf.to_string());
        }
        return;
    }
    if let Some(rest) = strip_ignore_case(cmd, "ip address ") {
        if rest.to_ascii_lowercase().contains("secondary") {
            return;
        }
        if stanza.ipv4_prefix.is_none() {
            stanza.ipv4_prefix = parse_ipv4_prefix(rest.trim());
        }
        return;
    }
    if let Some(rest) = strip_ignore_case(cmd, "ipv6 address ") {
        if stanza.ipv6_prefix.is_none() {
            stanza.ipv6_prefix = parse_ipv6_prefix(rest.trim());
        }
        return;
    }
    if let Some(rest) = strip_ignore_case(cmd, "switchport access vlan ") {
        stanza.vlan = parse_vlan(rest.trim());
        return;
    }
    if let Some(rest) = strip_ignore_case(cmd, "encapsulation dot1q ") {
        stanza.vlan = parse_vlan(rest.trim());
    }
}

/// Case-insensitive prefix strip that never indexes into a multi-byte
/// character. `line[..prefix.len()]` panics on a config line whose text is
/// non-ASCII, so the split point comes from the iterator instead.
fn strip_ignore_case<'a>(line: &'a str, prefix: &str) -> Option<&'a str> {
    let mut line_chars = line.char_indices();
    for expected in prefix.chars() {
        let (_, actual) = line_chars.next()?;
        if !actual.eq_ignore_ascii_case(&expected) {
            return None;
        }
    }
    let split = line_chars.next().map_or(line.len(), |(idx, _)| idx);
    Some(&line[split..])
}

fn parse_vlan(rest: &str) -> Option<i32> {
    let token = rest.split_whitespace().next()?;
    token.parse::<i32>().ok().filter(|vlan| *vlan > 0)
}

fn parse_ipv4_prefix(rest: &str) -> Option<String> {
    let mut parts = rest.split_whitespace();
    let addr = parts.next()?;
    if let Some((host, prefix_len)) = addr.split_once('/') {
        let len: u32 = prefix_len.parse().ok()?;
        if len > 32 {
            return None;
        }
        let ip = parse_ipv4(host)?;
        return Some(format!("{}/{}", ipv4_octets(ip & prefix_mask(len)), len));
    }
    let mask = parts.next()?;
    let ip = parse_ipv4(addr)?;
    let mask_u = parse_ipv4(mask)?;
    if !is_prefix_mask(mask_u) {
        return None;
    }
    let len = mask_u.count_ones();
    Some(format!("{}/{}", ipv4_octets(ip & mask_u), len))
}

fn parse_ipv6_prefix(rest: &str) -> Option<String> {
    let token = rest.split_whitespace().next()?;
    let (host, prefix_len) = token.split_once('/')?;
    let len: u32 = prefix_len.parse().ok()?;
    if len > 128 {
        return None;
    }
    let addr: std::net::Ipv6Addr = host.parse().ok()?;
    let masked = u128::from_be_bytes(addr.octets()) & ipv6_prefix_mask(len);
    Some(format!("{}/{}", std::net::Ipv6Addr::from(masked), len))
}

fn ipv6_prefix_mask(len: u32) -> u128 {
    if len == 0 {
        0
    } else {
        u128::MAX << (128 - len)
    }
}

fn parse_ipv4(s: &str) -> Option<u32> {
    let mut octets = [0u8; 4];
    let mut idx = 0;
    for part in s.split('.') {
        if idx >= 4 {
            return None;
        }
        octets[idx] = part.parse().ok()?;
        idx += 1;
    }
    if idx != 4 {
        return None;
    }
    Some(u32::from_be_bytes(octets))
}

fn ipv4_octets(ip: u32) -> String {
    let b = ip.to_be_bytes();
    format!("{}.{}.{}.{}", b[0], b[1], b[2], b[3])
}

fn prefix_mask(len: u32) -> u32 {
    if len == 0 { 0 } else { u32::MAX << (32 - len) }
}

fn is_prefix_mask(mask: u32) -> bool {
    if mask == 0 {
        return true;
    }
    let inverted = !mask;
    inverted & inverted.wrapping_add(1) == 0
}

#[cfg(test)]
mod unit_tests {
    use super::{is_prefix_mask, parse, parse_ipv4, parse_ipv4_prefix, parse_ipv6_prefix};

    #[test]
    fn ipv6_slash_form_is_network_cidr() {
        assert_eq!(
            parse_ipv6_prefix("2001:db8:1::1/64").as_deref(),
            Some("2001:db8:1::/64")
        );
        assert_eq!(
            parse_ipv6_prefix("2001:db8:1::2/64").as_deref(),
            parse_ipv6_prefix("2001:db8:1::1/64").as_deref(),
            "two hosts on one segment share a Prefix node"
        );
    }

    #[test]
    fn non_ascii_lines_do_not_panic() {
        let body = concat!(
            "interface GigabitEthernet0/1\n",
            " description \u{30cd}\u{30c3}\u{30c8}\u{30ef}\u{30fc}\u{30af}\n",
            " ip address 192.0.2.1 255.255.255.0\n",
            "\u{30cd}\u{30c3}\u{30c8}\u{30ef}\u{30fc}\u{30af}\n"
        );
        let facts = parse(body);
        assert_eq!(facts.len(), 1);
        assert_eq!(facts[0].if_name, "GigabitEthernet0/1");
        assert_eq!(facts[0].ipv4_prefix.as_deref(), Some("192.0.2.0/24"));
    }

    #[test]
    fn slash_form_is_network_cidr() {
        assert_eq!(
            parse_ipv4_prefix("192.0.2.1/24").as_deref(),
            Some("192.0.2.0/24")
        );
    }

    #[test]
    fn mask_form_is_network_cidr() {
        assert_eq!(
            parse_ipv4_prefix("198.51.100.1 255.255.255.0").as_deref(),
            Some("198.51.100.0/24")
        );
    }

    #[test]
    fn host_mask_is_slash_32() {
        assert_eq!(
            parse_ipv4_prefix("203.0.113.1 255.255.255.255").as_deref(),
            Some("203.0.113.1/32")
        );
    }

    #[test]
    fn documentation_ipv4_parses() {
        assert_eq!(parse_ipv4("192.0.2.1"), Some(0xC000_0201));
        assert!(is_prefix_mask(0xFFFF_FF00));
        assert!(!is_prefix_mask(0xFFFF_FE00 | 0x0000_0001));
    }
}
