// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

use crate::Prefix;

/// Per-member evidence retained for threat-intel expiry and matching.
/// Expiry is UTC microseconds; the Elixir adapter owns DateTime conversion.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Indicator {
    pub source: String,
    pub source_slug: Option<String>,
    pub severity: Option<u64>,
    pub expires_at: Option<(i64, u8)>,
    pub indicator_count: u64,
    pub tags: Vec<String>,
}

/// An owned entry, independent of BEAM heaps or database connections.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub prefix: Prefix,
    pub tags: Vec<String>,
    pub source: Option<String>,
    pub vrf: Option<String>,
    pub severity: Option<u64>,
    pub indicator_count: Option<u64>,
    pub expires_at: Option<(i64, u8)>,
    pub feed_sources: Option<Vec<String>>,
    pub indicators: Option<Vec<Indicator>>,
}

impl Entry {
    pub fn new(prefix: Prefix, tags: Vec<String>) -> Self {
        Self {
            prefix,
            tags,
            source: None,
            vrf: None,
            severity: None,
            indicator_count: None,
            expires_at: None,
            feed_sources: None,
            indicators: None,
        }
    }

    pub(crate) fn vrf_key(&self) -> &str {
        self.vrf.as_deref().unwrap_or("")
    }

    /// Match Trie.merge_entry: stable tag union, maximum severity, additive
    /// counts, permanent expiry preferred, and unmodified member evidence.
    pub(crate) fn merge(&mut self, newer: Self) {
        self.tags = stable_union(std::mem::take(&mut self.tags), newer.tags);
        self.source = newer.source.or(self.source.take());
        self.vrf = newer.vrf.or(self.vrf.take());
        self.severity = self.severity.max(newer.severity);
        self.indicator_count = match (self.indicator_count, newer.indicator_count) {
            (Some(a), Some(b)) => Some(a.checked_add(b).expect("indicator count overflow")),
            (a, b) => a.or(b),
        };
        self.expires_at = match (self.expires_at, newer.expires_at) {
            (Some(a), Some(b)) => Some(if a.0 > b.0 { a } else { b }),
            _ => None,
        };
        let feeds = stable_union(
            self.feed_sources.take().unwrap_or_default(),
            newer.feed_sources.unwrap_or_default(),
        )
        .into_iter()
        .filter(|source| !source.is_empty())
        .collect::<Vec<_>>();
        self.feed_sources = (!feeds.is_empty()).then_some(feeds);
        let mut members = self.indicators.take().unwrap_or_default();
        members.extend(newer.indicators.unwrap_or_default());
        self.indicators = (!members.is_empty()).then_some(members);
    }
}

fn stable_union(first: Vec<String>, second: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    first
        .into_iter()
        .chain(second)
        .filter(|tag| seen.insert(tag.clone()))
        .collect()
}
