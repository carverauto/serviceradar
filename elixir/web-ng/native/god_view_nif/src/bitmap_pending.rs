//! Loss-tolerant change hints. The source's full keyset pass remains authoritative.
use super::{check_time, deadline, section, Bitmap, Budget, Error, Index, BATCH_LIMIT};
use roaring::RoaringBitmap;
use std::sync::atomic::Ordering;
use std::sync::Arc;

const SERIALIZED_LIMIT: usize = 512 * 1024;
// A 512 KiB portable pending set of one-value containers accounts for under 16 MiB.
pub(super) const PENDING_QUEUE_HEADROOM: usize = 16 * 1024 * 1024;

pub(super) struct Pending {
    bitmap: Arc<Bitmap>,
    rescan_needed: bool,
    rescan_generation: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PendingStatus {
    pub pending_count: u64,
    pub serialized_bytes: usize,
    pub native_bytes: usize,
    pub rescan_needed: bool,
    pub rescan_generation: u64,
}

impl Pending {
    pub(super) fn new(budget: &Arc<Budget>) -> Result<Self, Error> {
        let bitmap = Bitmap::new(RoaringBitmap::new(), budget)?;
        budget.admit(std::iter::once(&bitmap.charge), std::iter::empty())?;
        Ok(Self {
            bitmap,
            rescan_needed: false,
            rescan_generation: 0,
        })
    }

    pub(super) fn status(&self) -> PendingStatus {
        PendingStatus {
            pending_count: self.bitmap.set.len(),
            serialized_bytes: self.bitmap.set.serialized_size(),
            // Struct metadata is part of the index's fixed allocation charge.
            native_bytes: self.bitmap.charge.bytes + std::mem::size_of::<Self>(),
            rescan_needed: self.rescan_needed,
            rescan_generation: self.rescan_generation,
        }
    }

    pub(super) fn clear(&mut self, budget: &Arc<Budget>) -> Result<(), Error> {
        self.replace(Bitmap::new(RoaringBitmap::new(), budget)?)?;
        self.rescan_needed = false;
        Ok(())
    }

    fn replace(&mut self, next: Arc<Bitmap>) -> Result<(), Error> {
        next.charge.budget.admit(
            std::iter::once(&next.charge),
            std::iter::once(&self.bitmap.charge),
        )?;
        self.bitmap = next;
        Ok(())
    }
}

impl Index {
    /// A rescan request advances a token even when a prior request is still pending.
    /// Only a completed full pass that observed this exact token may acknowledge it.
    pub fn mark_dirty(&self, ids: &[u32], request_rescan: bool) -> Result<PendingStatus, Error> {
        let end = deadline(1000)?;
        if ids.len() > BATCH_LIMIT || ids.contains(&0) {
            return Err("invalid_dirty_batch");
        }
        let mut pending = section(&self.pending)?;
        if self.closed.load(Ordering::Acquire) {
            return Err("closed");
        }
        let mut overflow = false;
        let next = if ids.iter().all(|id| pending.bitmap.set.contains(*id)) {
            None
        } else {
            // At most 500 new containers, plus the existing bounded bitmap clone.
            let scratch = self
                .budget
                .reserve(pending.bitmap.charge.bytes * 2 + 256 * 1024)?;
            let mut set = pending.bitmap.set.clone();
            set.extend(ids.iter().copied());
            overflow = set.serialized_size() > SERIALIZED_LIMIT;
            if overflow {
                set = RoaringBitmap::new();
            }
            // Keep the resulting allocation charged until it is replaced below.
            let next = Bitmap::new(set, &self.budget)?;
            drop(scratch);
            Some(next)
        };
        let generation = pending
            .rescan_generation
            .checked_add(u64::from(request_rescan || overflow))
            .ok_or("rescan_generation_exhausted")?;
        check_time(end)?;
        if let Some(next) = next {
            pending.replace(next)?;
        }
        pending.rescan_generation = generation;
        pending.rescan_needed |= request_rescan || overflow;
        Ok(pending.status())
    }

    /// Taking precedes source reads. On a failed read/publish the owner must mark
    /// these ordinals again; marks arriving during that work remain in this set.
    pub fn take_dirty(&self, limit: usize) -> Result<(Vec<u32>, PendingStatus), Error> {
        let end = deadline(1000)?;
        if !(1..=BATCH_LIMIT).contains(&limit) {
            return Err("invalid_dirty_batch");
        }
        let mut pending = section(&self.pending)?;
        if self.closed.load(Ordering::Acquire) {
            return Err("closed");
        }
        let ids: Vec<_> = pending.bitmap.set.iter().take(limit).collect();
        if !ids.is_empty() {
            let scratch = self
                .budget
                .reserve(pending.bitmap.charge.bytes * 2 + 4096)?;
            let mut set = pending.bitmap.set.clone();
            set.remove_smallest(ids.len() as u64);
            // Roaring retains its outer Vec capacity on removal. Clone only the
            // retained containers so the new charge also reflects actual storage.
            let next = Bitmap::new(set.clone(), &self.budget)?;
            drop(set);
            drop(scratch);
            check_time(end)?;
            pending.replace(next)?;
        }
        Ok((ids, pending.status()))
    }

    pub fn acknowledge_reconcile(&self, observed_generation: u64) -> Result<PendingStatus, Error> {
        let mut pending = section(&self.pending)?;
        if self.closed.load(Ordering::Acquire) {
            return Err("closed");
        }
        if pending.rescan_generation != observed_generation {
            return Err("stale_reconcile");
        }
        pending.rescan_needed = false;
        Ok(pending.status())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bitmap_index::Kind;

    fn index() -> Index {
        Index::new([1; 16], [2; 16], Kind::Device, vec!["vendor".into()]).unwrap()
    }

    #[test]
    fn taken_hints_requeue_without_losing_late_marks_or_unsigned_order() {
        let index = index();
        let baseline = index.status().unwrap().native_bytes;
        let marked = index.mark_dirty(&[u32::MAX, 1, 1, 1 << 31], true).unwrap();
        assert_eq!(marked.pending_count, 3);
        assert!(marked.rescan_needed);
        assert_eq!(index.mark_dirty(&[1], false).unwrap(), marked);
        let (taken, state) = index.take_dirty(2).unwrap();
        assert_eq!(taken, vec![1, 1 << 31]);
        assert_eq!(state.pending_count, 1);
        index.mark_dirty(&[1, 7], false).unwrap();
        index.mark_dirty(&taken, false).unwrap(); // Failed source read, retry later.
        let state = index
            .acknowledge_reconcile(marked.rescan_generation)
            .unwrap();
        assert!(!state.rescan_needed);
        assert_eq!(state.pending_count, 4); // Acknowledgement never eats later hints.
        assert_eq!(
            index.take_dirty(500).unwrap().0,
            vec![1, 7, 1 << 31, u32::MAX]
        );
        assert_eq!(index.status().unwrap().native_bytes, baseline);
        assert_eq!(index.mark_dirty(&[0], true), Err("invalid_dirty_batch"));
        assert_eq!(
            index.mark_dirty(&[1; 501], false),
            Err("invalid_dirty_batch")
        );
        assert_eq!(index.take_dirty(0), Err("invalid_dirty_batch"));
        assert_eq!(index.take_dirty(501), Err("invalid_dirty_batch"));
        index.close().unwrap();
        assert_eq!(index.mark_dirty(&[1], false), Err("closed"));
        assert_eq!(index.take_dirty(1), Err("closed"));
        assert_eq!(index.acknowledge_reconcile(1), Err("closed"));
    }

    #[test]
    fn sparse_overflow_fences_the_scan_and_releases_accounted_containers() {
        let index = index();
        let original = index.mark_dirty(&[], true).unwrap();
        let baseline = index.status().unwrap().native_bytes;
        let mut overflowed = None;
        // Invented ordinals: one entry in every possible high-16-bit container.
        for chunk in (0u32..65_536).collect::<Vec<_>>().chunks(500) {
            let ids: Vec<_> = chunk.iter().map(|n| (n << 16) | 1).collect();
            let state = index.mark_dirty(&ids, false).unwrap();
            assert!(state.serialized_bytes <= SERIALIZED_LIMIT);
            if state.rescan_generation == original.rescan_generation {
                assert!(state.native_bytes <= PENDING_QUEUE_HEADROOM);
            }
            if state.rescan_generation != original.rescan_generation {
                overflowed = Some(state);
                break;
            }
            let total = index.status().unwrap().native_bytes;
            assert_eq!(total - baseline, state.native_bytes - original.native_bytes);
        }
        let overflowed = overflowed.expect("sparse serialized input must exceed the real byte cap");
        assert_eq!(overflowed.pending_count, 0);
        assert!(overflowed.rescan_needed);
        assert_eq!(index.status().unwrap().native_bytes, baseline);
        assert_eq!(
            index.acknowledge_reconcile(original.rescan_generation),
            Err("stale_reconcile")
        );
        let newer = index.mark_dirty(&[u32::MAX], true).unwrap();
        assert_eq!(newer.rescan_generation, overflowed.rescan_generation + 1);
        assert_eq!(
            index.acknowledge_reconcile(overflowed.rescan_generation),
            Err("stale_reconcile")
        );
        assert!(index.take_dirty(1).unwrap().1.rescan_needed);
        assert!(
            !index
                .acknowledge_reconcile(newer.rescan_generation)
                .unwrap()
                .rescan_needed
        );
    }
}
