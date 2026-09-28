// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

#[cfg(panic = "abort")]
compile_error!("prefix_tags_nif requires panic=unwind to contain native panics");

use crate::{Entry, Indicator, Prefix, Trie};
use rustler::{NifMap, Resource, ResourceArc};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;

struct Builder(Mutex<Option<Trie>>);
struct Snapshot(Trie);

#[rustler::resource_impl]
impl Resource for Builder {}
#[rustler::resource_impl]
impl Resource for Snapshot {}

#[derive(NifMap)]
struct Row {
    prefix: String,
    tags: Vec<String>,
    source: Option<String>,
    vrf: Option<String>,
    severity: Option<u64>,
    indicator_count: Option<u64>,
    expires_at: Option<(i64, u8)>,
    feed_sources: Option<Vec<String>>,
    indicators: Option<Vec<Member>>,
}

#[derive(NifMap)]
struct Member {
    source: String,
    source_slug: Option<String>,
    severity: Option<u64>,
    expires_at: Option<(i64, u8)>,
    indicator_count: u64,
    tags: Vec<String>,
}

#[derive(NifMap)]
struct Counts {
    ipv4_prefixes: usize,
    ipv6_prefixes: usize,
    total_prefixes: usize,
}

fn contained<T>(operation: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    catch_unwind(AssertUnwindSafe(operation))
        .unwrap_or_else(|_| Err("prefix trie operation panicked".into()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn new_builder() -> Result<ResourceArc<Builder>, String> {
    contained(|| Ok(ResourceArc::new(Builder(Mutex::new(Some(Trie::new()))))))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn append(builder: ResourceArc<Builder>, rows: Vec<Row>) -> Result<bool, String> {
    contained(|| {
        let mut state = builder.0.lock().map_err(|_| "failed builder")?;
        // Taking ownership makes any error or panic invalidate the entire build.
        // A failed partial append must never become publishable.
        let mut trie = state.take().ok_or("consumed builder")?;
        for row in rows {
            let prefix = Prefix::parse(&row.prefix).ok_or("invalid prefix")?;
            trie.insert(Entry {
                prefix,
                tags: row.tags,
                source: row.source,
                vrf: row.vrf,
                severity: row.severity,
                indicator_count: row.indicator_count,
                expires_at: row.expires_at,
                feed_sources: row.feed_sources,
                indicators: row
                    .indicators
                    .map(|members| members.into_iter().map(Indicator::from).collect()),
            });
        }
        *state = Some(trie);
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn finish(builder: ResourceArc<Builder>) -> Result<ResourceArc<Snapshot>, String> {
    contained(|| {
        let trie = builder
            .0
            .lock()
            .map_err(|_| "failed builder")?
            .take()
            .ok_or("consumed builder")?;
        Ok(ResourceArc::new(Snapshot(trie)))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn lookup(snapshot: ResourceArc<Snapshot>, address: String) -> Result<Vec<Row>, String> {
    contained(|| {
        Ok(snapshot
            .0
            .lookup(&address)
            .into_iter()
            .map(Row::from)
            .collect())
    })
}

#[rustler::nif]
fn stats(snapshot: ResourceArc<Snapshot>) -> Result<Counts, String> {
    contained(|| {
        let stats = snapshot.0.stats();
        Ok(Counts {
            ipv4_prefixes: stats.ipv4_prefixes,
            ipv6_prefixes: stats.ipv6_prefixes,
            total_prefixes: stats.total_prefixes(),
        })
    })
}

impl From<&Entry> for Row {
    fn from(entry: &Entry) -> Self {
        Self {
            prefix: entry.prefix.to_string(),
            tags: entry.tags.clone(),
            source: entry.source.clone(),
            vrf: entry.vrf.clone(),
            severity: entry.severity,
            indicator_count: entry.indicator_count,
            expires_at: entry.expires_at,
            feed_sources: entry.feed_sources.clone(),
            indicators: entry
                .indicators
                .as_ref()
                .map(|members| members.iter().map(Member::from).collect()),
        }
    }
}

impl From<Member> for Indicator {
    fn from(member: Member) -> Self {
        Self {
            source: member.source,
            source_slug: member.source_slug,
            severity: member.severity,
            expires_at: member.expires_at,
            indicator_count: member.indicator_count,
            tags: member.tags,
        }
    }
}

impl From<&Indicator> for Member {
    fn from(member: &Indicator) -> Self {
        Self {
            source: member.source.clone(),
            source_slug: member.source_slug.clone(),
            severity: member.severity,
            expires_at: member.expires_at,
            indicator_count: member.indicator_count,
            tags: member.tags.clone(),
        }
    }
}
