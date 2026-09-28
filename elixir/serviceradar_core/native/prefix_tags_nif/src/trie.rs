// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

use crate::prefix::{branch, mask, parse_address};
use crate::{Entry, Prefix};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub ipv4_prefixes: usize,
    pub ipv6_prefixes: usize,
}

impl Stats {
    pub fn total_prefixes(self) -> usize {
        self.ipv4_prefixes + self.ipv6_prefixes
    }
}

/// Mutable during construction; immutable borrows serve lock-free lookups after
/// publication. Path compression creates at most two nodes per distinct prefix.
/// Child indices remain valid when the contiguous arena grows.
#[derive(Debug, Default)]
pub struct Trie {
    nodes: Vec<Node>,
    roots: [Option<usize>; 2],
    stats: Stats,
}

#[derive(Debug)]
struct Node {
    prefix: Prefix,
    children: [Option<usize>; 2],
    // In insertion order; reversed only when yielding matches.
    entries: Vec<Entry>,
}

impl Trie {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds or merges one normalized row. Distinct VRFs count as distinct
    /// entries, while the same prefix/VRF preserves its original position.
    pub fn insert(&mut self, entry: Entry) {
        let family = usize::from(!entry.prefix.ipv4);
        let (root, added) = self.insert_at(self.roots[family], entry);
        self.roots[family] = Some(root);
        if added {
            if family == 0 {
                self.stats.ipv4_prefixes += 1;
            } else {
                self.stats.ipv6_prefixes += 1;
            }
        }
    }

    pub fn stats(&self) -> Stats {
        self.stats
    }

    /// Returns borrowed entries, deepest prefix first and newest VRF first
    /// within a prefix. No snapshot copy is needed to serve a lookup.
    pub fn lookup(&self, address: &str) -> Vec<&Entry> {
        let Some((address, ipv4)) = parse_address(address) else {
            return Vec::new();
        };
        let mut current = self.roots[usize::from(!ipv4)];
        let mut matches = Vec::new();
        while let Some(index) = current {
            let node = &self.nodes[index];
            if !node.prefix.contains(address) {
                break;
            }
            matches.extend(&node.entries);
            if node.prefix.length == if ipv4 { 32 } else { 128 } {
                break;
            }
            current = node.children[branch(address, node.prefix.length)];
        }
        matches.reverse();
        matches
    }

    fn push_node(&mut self, prefix: Prefix, entries: Vec<Entry>) -> usize {
        let index = self.nodes.len();
        self.nodes.push(Node {
            prefix,
            children: [None, None],
            entries,
        });
        index
    }

    fn insert_at(&mut self, current: Option<usize>, entry: Entry) -> (usize, bool) {
        let Some(index) = current else {
            return (self.push_node(entry.prefix, vec![entry]), true);
        };
        let old = self.nodes[index].prefix;
        let new = entry.prefix;
        let shared = ((old.network ^ new.network).leading_zeros() as u8)
            .min(old.length)
            .min(new.length);

        if shared < old.length {
            // The new entry is an ancestor, or the two prefixes diverge in
            // the middle of a compressed edge. Introduce their common parent.
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
            return (parent, true);
        }

        if old.length == new.length {
            let entries = &mut self.nodes[index].entries;
            if let Some(previous) = entries.iter_mut().find(|e| e.vrf_key() == entry.vrf_key()) {
                previous.merge(entry);
                return (index, false);
            }
            entries.push(entry);
            return (index, true);
        }

        let side = branch(new.network, old.length);
        let (child, added) = self.insert_at(self.nodes[index].children[side], entry);
        self.nodes[index].children[side] = Some(child);
        (index, added)
    }
}
