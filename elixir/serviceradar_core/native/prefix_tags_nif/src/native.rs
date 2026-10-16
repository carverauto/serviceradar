// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

#[cfg(panic = "abort")]
compile_error!("prefix_tags_nif requires panic=unwind to contain native panics");

use crate::{Catalog, Entry, Indicator, Prefix, Trie};
use rustler::{Binary, Env, NifMap, OwnedBinary, Resource, ResourceArc};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;
use std::time::{Duration, Instant};

struct Builder(Mutex<Option<Trie>>);
struct Snapshot(Trie, Mutex<Option<Catalog>>);

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

#[derive(NifMap)]
struct CatalogStatus {
    available: bool,
    label_count: usize,
    native_bytes: usize,
    total_native_bytes: usize,
}

#[derive(NifMap)]
struct LabelPage {
    labels: Vec<String>,
    next_after: Option<String>,
}

fn catalog_info(catalog: Option<&Catalog>) -> CatalogStatus {
    CatalogStatus {
        available: catalog.is_some(),
        label_count: catalog.map_or(0, Catalog::label_count),
        native_bytes: catalog.map_or(0, Catalog::native_bytes),
        total_native_bytes: Catalog::total_native_bytes(),
    }
}

fn deadline(timeout_ms: u64) -> Result<Instant, String> {
    if !(1..=1_000).contains(&timeout_ms) {
        return Err("invalid_selector".into());
    }
    Ok(Instant::now() + Duration::from_millis(timeout_ms))
}

fn label_text<'a>(label: &'a Binary<'_>) -> Result<&'a str, String> {
    if label.is_empty() || label.len() > 256 {
        return Err("label_budget".into());
    }
    std::str::from_utf8(label.as_slice()).map_err(|_| "invalid_selector".into())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn prepare_catalog(
    snapshot: ResourceArc<Snapshot>,
    timeout_ms: u64,
) -> Result<CatalogStatus, String> {
    contained(|| {
        let deadline = deadline(timeout_ms)?;
        let mut catalog = snapshot.1.try_lock().map_err(|_| "catalog_busy")?;
        if catalog.is_none() {
            *catalog = Some(Catalog::build(&snapshot.0, deadline)?);
        }
        Ok(catalog_info(catalog.as_ref()))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn release_catalog(snapshot: ResourceArc<Snapshot>) -> Result<bool, String> {
    contained(|| {
        let mut catalog = snapshot.1.try_lock().map_err(|_| "catalog_busy")?;
        *catalog = None;
        Ok(true)
    })
}

#[rustler::nif]
fn catalog_status(snapshot: ResourceArc<Snapshot>) -> Result<CatalogStatus, String> {
    contained(|| {
        let catalog = snapshot.1.try_lock().map_err(|_| "catalog_busy")?;
        Ok(catalog_info(catalog.as_ref()))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn label_page(
    snapshot: ResourceArc<Snapshot>,
    after: Option<Binary<'_>>,
    limit: usize,
    timeout_ms: u64,
) -> Result<LabelPage, String> {
    contained(|| {
        let deadline = deadline(timeout_ms)?;
        let after = after.as_ref().map(label_text).transpose()?;
        let guard = snapshot.1.try_lock().map_err(|_| "catalog_busy")?;
        let catalog = guard.as_ref().ok_or("catalog_not_ready")?;
        let page = catalog.page(&snapshot.0, after, limit, deadline)?;
        Ok(LabelPage {
            labels: page.labels,
            next_after: page.next_after,
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn label_ranges<'a>(
    env: Env<'a>,
    snapshot: ResourceArc<Snapshot>,
    label: Binary<'a>,
    max_ranges: usize,
    max_bytes: usize,
    timeout_ms: u64,
) -> Result<Binary<'a>, String> {
    contained(|| {
        let deadline = deadline(timeout_ms)?;
        let label = label_text(&label)?;
        let guard = snapshot.1.try_lock().map_err(|_| "catalog_busy")?;
        let catalog = guard.as_ref().ok_or("catalog_not_ready")?;
        let bytes = catalog.ranges(&snapshot.0, label, max_ranges, max_bytes, deadline)?;
        let mut output = OwnedBinary::new(bytes.len()).ok_or("range_budget")?;
        output.as_mut_slice().copy_from_slice(&bytes);
        Ok(output.release(env))
    })
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
        Ok(ResourceArc::new(Snapshot(trie, Mutex::new(None))))
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
