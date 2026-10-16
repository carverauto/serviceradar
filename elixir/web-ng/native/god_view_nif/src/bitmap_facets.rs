//! Literal facet/tag prefixes share the exact index and its publication revision.
use super::{check_time, Bitmap, Budget, Charge, Error, Index, Revision};
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
            let _scratch = budget.reserve(2 * (bytes + live.charge.bytes) + 8192)?;
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
                let bitmap = Bitmap::new(set, budget)?;
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
    let mut result = Bitmap::new(RoaringBitmap::new(), &index.budget)?;
    if prefix {
        for ((facet, candidate), posting) in
            revision.facets.range((key.to_owned(), value.to_owned())..)
        {
            if facet != key || !candidate.starts_with(value) {
                break;
            }
            check_time(end)?;
            result = Bitmap::combine(&result, posting, 2, &index.budget)?;
        }
    } else if let Some(posting) = revision.facets.get(&(key.to_owned(), value.to_owned())) {
        result = posting.clone();
    }
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
            // Key presence remains exact even if that facet's values exceeded
            // the value-cardinality cap. The presence bitmap has no such cap.
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
