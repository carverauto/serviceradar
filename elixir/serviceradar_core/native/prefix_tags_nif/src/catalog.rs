// Copyright 2026 Carver Automation Corporation.
// SPDX-License-Identifier: Apache-2.0

use crate::{Prefix, Trie};
use std::mem::size_of;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const MAX_BYTES: usize = 4 * 1024 * 1024;
static RETAINED_BYTES: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Copy, Debug)]
struct LabelRef {
    node: u32,
    entry: u32,
    tag: u32,
}

#[derive(Debug)]
struct Charge(usize);

impl Charge {
    fn reserve(bytes: usize) -> Result<Self, &'static str> {
        RETAINED_BYTES
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |used| {
                used.checked_add(bytes).filter(|&next| next <= MAX_BYTES)
            })
            .map_err(|_| "catalog_budget")?;
        Ok(Self(bytes))
    }
}

impl Drop for Charge {
    fn drop(&mut self) {
        RETAINED_BYTES.fetch_sub(self.0, Ordering::AcqRel);
    }
}

/// A bounded reverse index into an immutable trie, prepared by a background
/// owner. Labels and prefixes stay in the trie; only their positions are copied.
#[derive(Debug)]
pub struct Catalog {
    // Drop storage before returning its reservation to other snapshot builders.
    references: Vec<LabelRef>,
    label_count: usize,
    charge: Charge,
}

pub struct LabelPage {
    pub labels: Vec<String>,
    pub next_after: Option<String>,
}

impl Catalog {
    pub fn build(trie: &Trie, deadline: Instant) -> Result<Self, &'static str> {
        let mut count = 0usize;
        for (_, _, entry) in trie.entries() {
            check(deadline)?;
            for (index, tag) in entry.tags.iter().enumerate() {
                if index % 256 == 0 {
                    check(deadline)?;
                }
                if !queryable_label(tag) {
                    continue;
                }
                count += 1;
                if count > (MAX_BYTES - size_of::<Self>()) / size_of::<LabelRef>() {
                    return Err("catalog_budget");
                }
            }
        }
        let charge = Charge::reserve(size_of::<Self>() + count * size_of::<LabelRef>())?;
        let mut references = Vec::new();
        references
            .try_reserve_exact(count)
            .map_err(|_| "catalog_budget")?;
        // The allocator may reserve extra capacity; never publish uncharged storage.
        if references.capacity() != count {
            return Err("catalog_budget");
        }
        for (node, entry_index, entry) in trie.entries() {
            check(deadline)?;
            for tag in 0..entry.tags.len() {
                if tag % 256 == 0 {
                    check(deadline)?;
                }
                if !queryable_label(&entry.tags[tag]) {
                    continue;
                }
                references.push(LabelRef {
                    node: u32::try_from(node).map_err(|_| "catalog_budget")?,
                    entry: u32::try_from(entry_index).map_err(|_| "catalog_budget")?,
                    tag: u32::try_from(tag).map_err(|_| "catalog_budget")?,
                });
            }
        }
        // Only background construction sorts. Its input is capped by the same
        // global four-MiB reservation; request handlers never build a catalog.
        references.sort_unstable_by_key(|r| {
            let entry = trie.entry(r.node as usize, r.entry as usize);
            (
                &entry.tags[r.tag as usize],
                !entry.prefix.ipv4,
                entry.prefix.network,
                entry.prefix.length,
            )
        });
        check(deadline)?;
        let label_count = references
            .iter()
            .enumerate()
            .filter(|&(i, r)| i == 0 || label(trie, r) != label(trie, &references[i - 1]))
            .count();
        check(deadline)?;
        Ok(Self {
            references,
            label_count,
            charge,
        })
    }

    pub fn label_count(&self) -> usize {
        self.label_count
    }
    pub fn native_bytes(&self) -> usize {
        self.charge.0
    }
    pub fn total_native_bytes() -> usize {
        RETAINED_BYTES.load(Ordering::Acquire)
    }

    pub fn page(
        &self,
        trie: &Trie,
        after: Option<&str>,
        limit: usize,
        deadline: Instant,
    ) -> Result<LabelPage, &'static str> {
        if !(1..=50).contains(&limit) {
            return Err("invalid_selector");
        }
        if let Some(after) = after {
            validate_label(after)?;
        }
        check(deadline)?;
        let now = now_us();
        let mut offset = after.map_or(0, |after| {
            self.references.partition_point(|r| label(trie, r) <= after)
        });
        let mut labels = Vec::with_capacity(limit);
        while offset < self.references.len() && labels.len() < limit {
            check(deadline)?;
            let current = label(trie, &self.references[offset]);
            let next =
                offset + self.references[offset..].partition_point(|r| label(trie, r) == current);
            let visible = !surrounding_whitespace(current)
                && self.references[offset..next]
                    .iter()
                    .any(|reference| !reference_expired(trie, reference, now));
            offset = next;
            if visible {
                labels.push(current.to_owned());
            }
        }
        let next_after = (offset < self.references.len()).then(|| labels.last().unwrap().clone());
        Ok(LabelPage { labels, next_after })
    }

    /// Sorted, disjoint ranges: family byte, big-endian inclusive low/high u128.
    /// IPv4 occupies the low 32 bits. Overlapping VRFs and ancestors are a union,
    /// matching the existing lookup's full chain rather than a winner override.
    pub fn ranges(
        &self,
        trie: &Trie,
        wanted: &str,
        max_ranges: usize,
        max_bytes: usize,
        deadline: Instant,
    ) -> Result<Vec<u8>, &'static str> {
        validate_label(wanted)?;
        if !(1..=4096).contains(&max_ranges) || !(1..=262_144).contains(&max_bytes) {
            return Err("invalid_selector");
        }
        check(deadline)?;
        let start = self.references.partition_point(|r| label(trie, r) < wanted);
        let end = start + self.references[start..].partition_point(|r| label(trie, r) == wanted);
        if start == end {
            return Ok(Vec::new());
        }
        let capacity = max_ranges.min(max_bytes / 33) * 33;
        let mut output = Vec::new();
        output
            .try_reserve_exact(capacity)
            .map_err(|_| "range_budget")?;
        let now = now_us();
        let mut pending: Option<(u8, u128, u128)> = None;
        for (i, reference) in self.references[start..end].iter().enumerate() {
            if i % 256 == 0 {
                check(deadline)?;
            }
            let entry = trie.entry(reference.node as usize, reference.entry as usize);
            if entry.expires_at.is_some_and(|(at, _)| at <= now) {
                continue;
            }
            let range = numeric_range(entry.prefix);
            match pending.as_mut() {
                Some(previous)
                    if previous.0 == range.0 && range.1 <= previous.2.saturating_add(1) =>
                {
                    previous.2 = previous.2.max(range.2);
                }
                _ => {
                    if let Some(previous) = pending {
                        append_range(&mut output, previous, capacity)?;
                    }
                    pending = Some(range);
                }
            }
        }
        if let Some(range) = pending {
            append_range(&mut output, range, capacity)?;
        }
        check(deadline)?;
        Ok(output)
    }
}

fn label<'a>(trie: &'a Trie, reference: &LabelRef) -> &'a str {
    &trie
        .entry(reference.node as usize, reference.entry as usize)
        .tags[reference.tag as usize]
}

fn numeric_range(prefix: Prefix) -> (u8, u128, u128) {
    let (family, low, width) = if prefix.ipv4 {
        (4, prefix.network >> 96, 32)
    } else {
        (6, prefix.network, 128)
    };
    let bits = width - prefix.length;
    let hosts = if bits == 128 {
        u128::MAX
    } else {
        (1u128 << bits) - 1
    };
    (family, low, low | hosts)
}

fn append_range(
    output: &mut Vec<u8>,
    range: (u8, u128, u128),
    capacity: usize,
) -> Result<(), &'static str> {
    if output.len() + 33 > capacity {
        return Err("range_budget");
    }
    output.push(range.0);
    output.extend_from_slice(&range.1.to_be_bytes());
    output.extend_from_slice(&range.2.to_be_bytes());
    Ok(())
}

fn queryable_label(label: &str) -> bool {
    validate_label(label).is_ok()
}

fn surrounding_whitespace(label: &str) -> bool {
    label.starts_with(char::is_whitespace) || label.ends_with(char::is_whitespace)
}

fn now_us() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| i64::try_from(elapsed.as_micros()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

fn reference_expired(trie: &Trie, reference: &LabelRef, now: i64) -> bool {
    trie.entry(reference.node as usize, reference.entry as usize)
        .expires_at
        .is_some_and(|(at, _)| at <= now)
}

fn validate_label(label: &str) -> Result<(), &'static str> {
    if label.is_empty() || label.len() > 256 || surrounding_whitespace(label) {
        Err("label_budget")
    } else {
        Ok(())
    }
}

fn check(deadline: Instant) -> Result<(), &'static str> {
    if Instant::now() >= deadline {
        Err("deadline_exceeded")
    } else {
        Ok(())
    }
}
