use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// Canonical network prefix. IPv4 uses the most significant 32 bits so both
/// address families share the same prefix comparison and trie branch logic.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Prefix {
    pub(crate) network: u128,
    pub(crate) length: u8,
    pub(crate) ipv4: bool,
}

impl Prefix {
    pub fn parse(text: &str) -> Option<Self> {
        let (address, length) = match text.trim().split_once('/') {
            Some((address, length)) => (address, Some(length.trim().parse::<u8>().ok()?)),
            None => (text, None),
        };
        let mapped = address.contains(':');
        let (address, ipv4) = parse_address(address)?;
        let width = if ipv4 { 32 } else { 128 };
        let mut length = length.unwrap_or(width);
        if ipv4 && mapped && (96..=128).contains(&length) {
            length -= 96;
        }
        if length > width {
            return None;
        }
        Some(Self {
            network: mask(address, length),
            length,
            ipv4,
        })
    }

    pub fn contains_ip(self, ip: IpAddr) -> bool {
        let (address, ipv4) = match ip {
            IpAddr::V4(v4) => (u128::from(u32::from(v4)) << 96, true),
            IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
                Some(v4) => (u128::from(u32::from(v4)) << 96, true),
                None => (u128::from(v6), false),
            },
        };
        self.ipv4 == ipv4 && mask(address, self.length) == self.network
    }

    pub(crate) fn contains(self, address: u128) -> bool {
        mask(address, self.length) == self.network
    }
}

pub fn parse_cidr_list(cidrs: &[String]) -> Vec<Prefix> {
    cidrs.iter().filter_map(|c| Prefix::parse(c)).collect()
}

pub fn ip_in_cidrs(ip: IpAddr, cidrs: &[Prefix]) -> bool {
    cidrs.iter().any(|prefix| prefix.contains_ip(ip))
}

/// Truncate client IP host bits: IPv4 -> `/24` (e.g. `198.51.100.42` -> `198.51.100.0`),
/// IPv6 -> `/48` (e.g. `2001:db8:abcd:1234::5` -> `2001:db8:abcd::`).
pub fn truncate_ip(ip: IpAddr) -> String {
    match ip {
        IpAddr::V4(v4) => {
            let masked = u32::from(v4) & 0xffff_ff00;
            Ipv4Addr::from(masked).to_string()
        }
        IpAddr::V6(v6) => {
            if let Some(mapped) = v6.to_ipv4_mapped() {
                let masked = u32::from(mapped) & 0xffff_ff00;
                return Ipv4Addr::from(masked).to_string();
            }
            let masked = u128::from(v6) & (u128::MAX << (128 - 48));
            Ipv6Addr::from(masked).to_string()
        }
    }
}

/// Subnet key for per-subnet token-bucket rate limiting (`/24` IPv4, `/48` IPv6).
pub fn subnet_bucket_key(ip: IpAddr) -> String {
    match ip {
        IpAddr::V4(_) => format!("{}/24", truncate_ip(ip)),
        IpAddr::V6(v6) => {
            if v6.to_ipv4_mapped().is_some() {
                format!("{}/24", truncate_ip(ip))
            } else {
                format!("{}/48", truncate_ip(ip))
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct TagEntry {
    pub prefix: Prefix,
    pub tag: String,
}

#[derive(Debug)]
struct Node {
    prefix: Prefix,
    children: [Option<usize>; 2],
    entries: Vec<TagEntry>,
}

/// Longest-prefix-match CIDR trie ported from `prefix_tags_nif`.
#[derive(Debug, Default, Clone)]
pub struct TagTrie {
    nodes: Vec<Node>,
    roots: [Option<usize>; 2],
}

impl Clone for Node {
    fn clone(&self) -> Self {
        Self {
            prefix: self.prefix,
            children: self.children,
            entries: self.entries.clone(),
        }
    }
}

impl TagTrie {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(&mut self, cidr: &str, tag: impl Into<String>) -> bool {
        let Some(prefix) = Prefix::parse(cidr) else {
            return false;
        };
        let tag = tag.into().trim().to_string();
        if tag.is_empty() {
            return false;
        }
        let family = usize::from(!prefix.ipv4);
        let root = self.insert_at(self.roots[family], TagEntry { prefix, tag });
        self.roots[family] = Some(root);
        true
    }

    pub fn lookup(&self, ip: IpAddr) -> Option<&str> {
        let (address, ipv4) = ip_to_key(ip);
        let mut current = self.roots[usize::from(!ipv4)];
        let mut best: Option<&str> = None;
        while let Some(index) = current {
            let node = &self.nodes[index];
            if !node.prefix.contains(address) {
                break;
            }
            if let Some(last) = node.entries.last() {
                best = Some(last.tag.as_str());
            }
            if node.prefix.length == if ipv4 { 32 } else { 128 } {
                break;
            }
            current = node.children[branch(address, node.prefix.length)];
        }
        best
    }

    fn push_node(&mut self, prefix: Prefix, entries: Vec<TagEntry>) -> usize {
        let index = self.nodes.len();
        self.nodes.push(Node {
            prefix,
            children: [None, None],
            entries,
        });
        index
    }

    fn insert_at(&mut self, current: Option<usize>, entry: TagEntry) -> usize {
        let Some(index) = current else {
            return self.push_node(entry.prefix, vec![entry]);
        };
        let old = self.nodes[index].prefix;
        let new = entry.prefix;
        let shared = ((old.network ^ new.network).leading_zeros() as u8)
            .min(old.length)
            .min(new.length);

        if shared < old.length {
            let parent_prefix = Prefix {
                network: mask(new.network, shared),
                length: shared,
                ipv4: new.ipv4,
            };
            let parent = self.push_node(parent_prefix, Vec::new());
            self.nodes[parent].children[branch(old.network, shared)] = Some(index);
            if shared == new.length {
                self.nodes[parent].entries.push(entry);
            } else {
                let child = self.push_node(new, vec![entry]);
                self.nodes[parent].children[branch(new.network, shared)] = Some(child);
            }
            return parent;
        }

        if old.length == new.length {
            self.nodes[index].entries.push(entry);
            return index;
        }

        let side = branch(new.network, old.length);
        let child = self.insert_at(self.nodes[index].children[side], entry);
        self.nodes[index].children[side] = Some(child);
        index
    }
}

fn ip_to_key(ip: IpAddr) -> (u128, bool) {
    match ip {
        IpAddr::V4(v4) => (u128::from(u32::from(v4)) << 96, true),
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => (u128::from(u32::from(v4)) << 96, true),
            None => (u128::from(v6), false),
        },
    }
}

fn parse_address(text: &str) -> Option<(u128, bool)> {
    text.trim().parse::<IpAddr>().ok().map(ip_to_key)
}

fn mask(address: u128, length: u8) -> u128 {
    if length == 0 {
        0
    } else {
        address & (u128::MAX << (128 - length))
    }
}

fn branch(address: u128, depth: u8) -> usize {
    ((address >> (127 - depth)) & 1) as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn longest_prefix_match_prefers_more_specific_cidr() {
        let mut trie = TagTrie::new();
        assert!(trie.insert("198.51.100.0/24", "site:region-a"));
        assert!(trie.insert("198.51.100.64/26", "site:branch-01"));
        assert!(trie.insert("2001:db8:abcd::/48", "site:v6-branch"));

        assert_eq!(
            trie.lookup("198.51.100.42".parse().unwrap()),
            Some("site:region-a")
        );
        assert_eq!(
            trie.lookup("198.51.100.70".parse().unwrap()),
            Some("site:branch-01")
        );
        assert_eq!(trie.lookup("203.0.113.5".parse().unwrap()), None);
        assert_eq!(
            trie.lookup("2001:db8:abcd:1234::5".parse().unwrap()),
            Some("site:v6-branch")
        );
    }

    #[test]
    fn ip_truncation_zeroes_host_bits_for_v4_and_v6() {
        assert_eq!(
            truncate_ip("198.51.100.42".parse().unwrap()),
            "198.51.100.0"
        );
        assert_eq!(
            truncate_ip("2001:db8:abcd:1234::5".parse().unwrap()),
            "2001:db8:abcd::"
        );
        assert_eq!(
            subnet_bucket_key("198.51.100.42".parse().unwrap()),
            "198.51.100.0/24"
        );
        assert_eq!(
            subnet_bucket_key("2001:db8:abcd:1234::5".parse().unwrap()),
            "2001:db8:abcd::/48"
        );
    }
}
