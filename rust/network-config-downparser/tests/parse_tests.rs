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

use network_config_downparser::{InterfaceFact, PARSER_VERSION, parse};

/// Invented IOS-like running-config. Hostnames and addresses are documentation
/// values (RFC 5737 / RFC 3849). This is not an export from a live NA instance.
const SYNTHETIC_IOS: &str = r#"
!
hostname host01.example.com
!
interface GigabitEthernet0/1
 description Uplink to core
 ip address 192.0.2.1 255.255.255.0
 ipv6 address 2001:db8:1::1/64
 switchport access vlan 10
 no shutdown
!
interface GigabitEthernet0/2
 description Spare access port
 shutdown
 ip address 198.51.100.1 255.255.255.0
!
interface Loopback0
 description Router-id
 ip address 203.0.113.1 255.255.255.255
 ip vrf forwarding MGMT
!
interface GigabitEthernet0/3
 description No addressing
!
interface range GigabitEthernet1/0/1-4
 description skipped in v1
!
"#;

#[test]
fn parser_version_is_network_config_v1() {
    assert_eq!(PARSER_VERSION, "network_config_v1");
}

#[test]
fn extracts_interface_stanzas_from_invented_ios() {
    let facts = parse(SYNTHETIC_IOS);
    assert_eq!(
        facts.len(),
        4,
        "interface range is skipped; four named stanzas remain"
    );

    assert_eq!(
        facts[0],
        InterfaceFact {
            if_name: "GigabitEthernet0/1".to_string(),
            ipv4_prefix: Some("192.0.2.0/24".to_string()),
            ipv6_prefix: Some("2001:db8:1::/64".to_string()),
            vlan: Some(10),
            description: Some("Uplink to core".to_string()),
            shutdown: false,
            vrf: None,
        }
    );
    assert_eq!(
        facts[1],
        InterfaceFact {
            if_name: "GigabitEthernet0/2".to_string(),
            ipv4_prefix: Some("198.51.100.0/24".to_string()),
            ipv6_prefix: None,
            vlan: None,
            description: Some("Spare access port".to_string()),
            shutdown: true,
            vrf: None,
        }
    );
    assert_eq!(
        facts[2],
        InterfaceFact {
            if_name: "Loopback0".to_string(),
            ipv4_prefix: Some("203.0.113.1/32".to_string()),
            ipv6_prefix: None,
            vlan: None,
            description: Some("Router-id".to_string()),
            shutdown: false,
            vrf: Some("MGMT".to_string()),
        }
    );
    assert_eq!(facts[3].if_name, "GigabitEthernet0/3");
    assert_eq!(facts[3].ipv4_prefix, None);
    assert!(!facts[3].shutdown);
}

#[test]
fn hostname_is_not_an_interface_fact() {
    let facts = parse(SYNTHETIC_IOS);
    assert!(facts.iter().all(|f| f.if_name != "host01.example.com"));
}

#[test]
fn secondary_ipv4_is_ignored() {
    let body = "interface GigabitEthernet0/1\n ip address 192.0.2.1 255.255.255.0\n ip address 192.0.2.129 255.255.255.128 secondary\n";
    let facts = parse(body);
    assert_eq!(facts[0].ipv4_prefix.as_deref(), Some("192.0.2.0/24"));
}

#[test]
fn empty_body_yields_no_facts() {
    assert!(parse("").is_empty());
    assert!(parse("!\nhostname host01.example.com\n!\n").is_empty());
}
