//! Literal facet/tag prefixes share the exact index and its publication revision.
use super::{bitmap_bytes, check_time, Bitmap, Budget, Charge, Error, Index, Revision};
use roaring::RoaringBitmap;
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;

#[derive(Clone)]
pub(super) enum Presence {
    // Fully populated facets need no duplicate sparse live-universe allocation.
    AllLive,
    Present(Arc<Bitmap>),
    Absent(Arc<Bitmap>),
}
impl Presence {
    pub(super) fn subset(&self) -> Option<&Arc<Bitmap>> {
        match self {
            Self::AllLive => None,
            Self::Present(set) | Self::Absent(set) => Some(set),
        }
    }
    pub(super) fn charge(&self) -> Option<&Charge> {
        self.subset().map(|set| &set.charge)
    }
    fn members(&self, revision: &Revision, budget: &Arc<Budget>) -> Result<Arc<Bitmap>, Error> {
        match self {
            Self::AllLive => Ok(revision.live.clone()),
            Self::Present(set) => Ok(set.clone()),
            Self::Absent(set) => Bitmap::combine(&revision.live, set, 3, budget),
        }
    }
}

pub(super) fn refresh_presence(
    old: &Revision,
    live: &Arc<Bitmap>,
    changed: &RoaringBitmap,
    additions: &BTreeMap<String, RoaringBitmap>,
    budget: &Arc<Budget>,
    end: Instant,
) -> Result<BTreeMap<String, Presence>, Error> {
    // Both intermediates contain only this bounded batch, even when the live
    // universe is large. Reserve before materializing them.
    let _batch_scratch = budget.reserve(4 * bitmap_bytes(changed) + 4096)?;
    let empty = RoaringBitmap::new();
    let current_changed = &live.set & changed;
    old.presence
        .iter()
        .map(|(key, presence)| {
            check_time(end)?;
            let before = presence.subset().map_or(&empty, |set| &set.set);
            let inverted = !matches!(presence, Presence::Present(_));
            let present_add = additions.get(key).unwrap_or(&empty);
            let missing_add;
            let add = if inverted {
                missing_add = &current_changed - present_add;
                &missing_add
            } else {
                present_add
            };
            if add.is_subset(before) && before.intersection_len(changed) == add.len() {
                return Ok((key.clone(), presence.clone()));
            }
            let bytes = presence.charge().map_or(0, |charge| charge.bytes);
            let scratch = budget.reserve(2 * (bytes + live.charge.bytes) + 8192)?;
            let mut set = before - changed;
            set |= add;
            let represented = if inverted {
                live.set.len() - set.len()
            } else {
                set.len()
            };
            let next = if represented == live.set.len() {
                Presence::AllLive
            } else {
                // Sparse absences are cheaper than a second nearly-full universe;
                // rare tags retain their sparse positive membership instead.
                let absent = represented > live.set.len() / 2;
                if absent != inverted {
                    set = &live.set - &set;
                }
                let bitmap = Bitmap::from_reserved(set, scratch)?;
                if absent {
                    Presence::Absent(bitmap)
                } else {
                    Presence::Present(bitmap)
                }
            };
            Ok((key.clone(), next))
        })
        .collect()
}

fn present_result(
    revision: &Revision,
    key: &str,
    result: Arc<Bitmap>,
    budget: &Arc<Budget>,
) -> Result<Arc<Bitmap>, Error> {
    match revision.presence.get(key) {
        Some(Presence::AllLive) => Ok(result),
        Some(Presence::Present(present)) => Bitmap::combine(&result, present, 1, budget),
        Some(Presence::Absent(absent)) => Bitmap::combine(&result, absent, 3, budget),
        None => Err("unsupported_facet"),
    }
}

fn union_postings<'a>(
    postings: impl Iterator<Item = &'a Arc<Bitmap>>,
    budget: &Arc<Budget>,
    end: Instant,
) -> Result<Arc<Bitmap>, Error> {
    // Each occupied level combines 2^level postings. A growing result is copied
    // logarithmically, not once for every distinct matching value. The fixed
    // stack is covered by the query's input reservation; combine reserves every
    // bitmap allocation and each merge observes the original request deadline.
    let mut levels: [Option<Arc<Bitmap>>; usize::BITS as usize] = std::array::from_fn(|_| None);
    for posting in postings {
        check_time(end)?;
        let mut carry = posting.clone();
        let mut level = 0;
        loop {
            let slot = levels.get_mut(level).ok_or("native_memory_budget")?;
            match slot.take() {
                Some(previous) => {
                    check_time(end)?;
                    carry = Bitmap::combine(&previous, &carry, 2, budget)?;
                }
                None => {
                    *slot = Some(carry);
                    break;
                }
            }
            level += 1;
        }
    }
    let mut result: Option<Arc<Bitmap>> = None;
    for posting in levels.into_iter().flatten() {
        check_time(end)?;
        result = Some(match result {
            Some(previous) => Bitmap::combine(&previous, &posting, 2, budget)?,
            None => posting,
        });
    }
    result.map_or_else(|| Bitmap::new(RoaringBitmap::new(), budget), Ok)
}

fn value_result(
    index: &Index,
    revision: &Revision,
    key: &str,
    value: &str,
    prefix: bool,
    present: bool,
    end: Instant,
) -> Result<Arc<Bitmap>, Error> {
    if revision.unavailable.contains(key) {
        return Err("facet_unavailable");
    }
    let result = if prefix {
        let postings = revision
            .facets
            .range((key.to_owned(), value.to_owned())..)
            .take_while(|((facet, candidate), _)| facet == key && candidate.starts_with(value))
            .map(|(_, posting)| posting);
        union_postings(postings, &index.budget, end)?
    } else if let Some(posting) = revision.facets.get(&(key.to_owned(), value.to_owned())) {
        posting.clone()
    } else {
        Bitmap::new(RoaringBitmap::new(), &index.budget)?
    };
    if present {
        present_result(revision, key, result, &index.budget)
    } else {
        Ok(result)
    }
}

pub(super) fn select(
    index: &Index,
    revision: &Revision,
    opcode: u8,
    key: &str,
    value: &[u8],
    end: Instant,
) -> Result<Arc<Bitmap>, Error> {
    let value = std::str::from_utf8(value).map_err(|_| "invalid_expression")?;
    if opcode == 0 || opcode == 4 {
        if !index.supported.contains(key) {
            return Err("unsupported_facet");
        }
        return value_result(index, revision, key, value, opcode == 4, opcode == 4, end);
    }
    let key_prefix = format!("tag:{key}");
    let mut result = Bitmap::new(RoaringBitmap::new(), &index.budget)?;
    for key in index.supported.range(key_prefix.clone()..) {
        if !key.starts_with(&key_prefix) {
            break;
        }
        check_time(end)?;
        let matching = if opcode == 5 {
            // Key presence remains exact even when an oversized scalar value
            // made exact value matching unavailable.
            revision
                .presence
                .get(key)
                .ok_or("unsupported_facet")?
                .members(revision, &index.budget)?
        } else {
            // Evaluate the value against this same key before unioning owners.
            value_result(index, revision, key, value, opcode == 7, true, end)?
        };
        result = Bitmap::combine(&result, &matching, 2, &index.budget)?;
    }
    Ok(result)
}
