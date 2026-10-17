//! Packed numeric address ownership, published with the scalar membership revision.
//!
//! Forward leaves support address ranges; reverse leaves remove a device's entire
//! previous assignment without a fleet scan. Unchanged leaves are shared by pins.
use super::{bitmap_bytes, check_time, Bitmap, Budget, Charge, Error};
use roaring::RoaringBitmap;
use std::cmp::Ordering;
use std::mem::size_of;
use std::sync::Arc;
use std::time::Instant;

const LEAF_ROWS: usize = 512;
pub(super) const STAGE_BYTES: usize = 16 * 1024 * 1024;
pub(super) const MAX_RANGES: usize = 4096;
pub(super) const SELECTOR_BYTES: usize = 256 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct Entry<const N: usize> {
    pub address: [u8; N],
    pub ordinal: u32,
}
impl<const N: usize> Entry<N> {
    fn cmp<const REVERSE: bool>(&self, other: &Self) -> Ordering {
        if REVERSE {
            (self.ordinal, self.address).cmp(&(other.ordinal, other.address))
        } else {
            (self.address, self.ordinal).cmp(&(other.address, other.ordinal))
        }
    }
}
struct Leaf<const N: usize> {
    entries: Box<[Entry<N>]>,
    charge: Charge,
}
struct Tree<const N: usize, const REVERSE: bool> {
    leaves: Vec<Arc<Leaf<N>>>,
    count: usize,
    charge: Charge,
}
impl<const N: usize, const REVERSE: bool> Tree<N, REVERSE> {
    fn empty(budget: &Arc<Budget>) -> Result<Arc<Self>, Error> {
        Ok(Arc::new(Self {
            leaves: Vec::new(),
            count: 0,
            charge: budget.reserve(256)?,
        }))
    }
    fn charges(&self) -> impl Iterator<Item = &Charge> + Clone {
        std::iter::once(&self.charge).chain(self.leaves.iter().map(|leaf| &leaf.charge))
    }
    fn retiring(&self, sole: bool) -> impl Iterator<Item = &Charge> + Clone {
        std::iter::once(&self.charge).filter(move |_| sole).chain(
            self.leaves.iter().filter_map(move |leaf| {
                (sole && Arc::strong_count(leaf) == 1).then_some(&leaf.charge)
            }),
        )
    }
    fn push(
        leaves: &mut Vec<Arc<Leaf<N>>>,
        entries: &[Entry<N>],
        budget: &Arc<Budget>,
    ) -> Result<(), Error> {
        for chunk in entries.chunks(LEAF_ROWS) {
            let charge = budget.reserve(128 + size_of::<Entry<N>>() * chunk.len())?;
            Self::append(
                leaves,
                Arc::new(Leaf {
                    entries: chunk.into(),
                    charge,
                }),
                budget,
            )?;
        }
        Ok(())
    }
    fn append(
        leaves: &mut Vec<Arc<Leaf<N>>>,
        leaf: Arc<Leaf<N>>,
        budget: &Arc<Budget>,
    ) -> Result<(), Error> {
        if leaves.last().is_some_and(|previous| {
            previous.entries.len() < LEAF_ROWS / 2 || leaf.entries.len() < LEAF_ROWS / 2
        }) {
            let previous = leaves.pop().ok_or("invalid_address_index")?;
            let total = previous.entries.len() + leaf.entries.len();
            let _scratch = budget.reserve(256 + total * size_of::<Entry<N>>())?;
            let mut entries = Vec::with_capacity(total);
            entries.extend_from_slice(&previous.entries);
            entries.extend_from_slice(&leaf.entries);
            let width = if total > LEAF_ROWS {
                total.div_ceil(2)
            } else {
                total
            };
            for chunk in entries.chunks(width) {
                let charge = budget.reserve(128 + size_of::<Entry<N>>() * chunk.len())?;
                leaves.push(Arc::new(Leaf {
                    entries: chunk.into(),
                    charge,
                }));
            }
        } else {
            leaves.push(leaf);
        }
        Ok(())
    }
    fn replace(
        self: &Arc<Self>,
        removed: &mut [Entry<N>],
        added: &mut [Entry<N>],
        budget: &Arc<Budget>,
        end: Instant,
    ) -> Result<Arc<Self>, Error> {
        removed.sort_unstable_by(Entry::cmp::<REVERSE>);
        added.sort_unstable_by(Entry::cmp::<REVERSE>);
        if removed == added {
            return Ok(self.clone());
        }
        // A touched leaf can split once beyond its full incoming chunks. Reserve
        // the directory's complete upper bound before allocation, avoiding an
        // uncharged Vec growth while old request pins still retain the prior one.
        let capacity =
            self.leaves.len() + added.len() / LEAF_ROWS + added.len().min(self.leaves.len()) + 1;
        let scratch = budget.reserve(256 + 8 * capacity)?;
        let mut leaves = Vec::with_capacity(capacity);
        let mut deletes = removed;
        let mut inserts = added;
        let mut count = self.count;
        for leaf in &self.leaves {
            check_time(end)?;
            let upper = leaf.entries.last().ok_or("invalid_address_index")?;
            let nd = deletes.partition_point(|entry| entry.cmp::<REVERSE>(upper).is_le());
            let na = inserts.partition_point(|entry| entry.cmp::<REVERSE>(upper).is_le());
            if nd == 0 && na == 0 {
                Self::append(&mut leaves, leaf.clone(), budget)?;
                continue;
            }
            let _merge = budget.reserve(256 + (leaf.entries.len() + na) * size_of::<Entry<N>>())?;
            let mut next = Vec::with_capacity(leaf.entries.len() + na);
            for entry in &leaf.entries {
                if deletes[..nd]
                    .binary_search_by(|candidate| candidate.cmp::<REVERSE>(entry))
                    .is_err()
                {
                    next.push(*entry);
                }
            }
            next.extend_from_slice(&inserts[..na]);
            next.sort_unstable_by(Entry::cmp::<REVERSE>);
            next.dedup();
            count = count - leaf.entries.len() + next.len();
            Self::push(&mut leaves, &next, budget)?;
            deletes = &mut deletes[nd..];
            inserts = &mut inserts[na..];
        }
        if !deletes.is_empty() {
            return Err("invalid_address_index");
        }
        // Duplicates in the incoming complete assignment have already been
        // canonicalized by Addresses::replace before reaching either ordering.
        count += inserts.len();
        Self::push(&mut leaves, inserts, budget)?;
        let charge = budget.reserve(256 + leaves.capacity() * size_of::<Arc<Leaf<N>>>())?;
        drop(scratch);
        Ok(Arc::new(Self {
            leaves,
            count,
            charge,
        }))
    }
}
impl<const N: usize> Tree<N, true> {
    fn previous(
        &self,
        changed: &[u32],
        output: &mut Vec<Entry<N>>,
        budget: &Arc<Budget>,
        end: Instant,
    ) -> Result<Vec<Charge>, Error> {
        let mut charges = Vec::new();
        for ordinal in changed {
            let first = self.leaves.partition_point(|leaf| {
                leaf.entries
                    .last()
                    .is_some_and(|entry| entry.ordinal < *ordinal)
            });
            for leaf in &self.leaves[first..] {
                check_time(end)?;
                if leaf.entries[0].ordinal > *ordinal {
                    break;
                }
                for entry in leaf
                    .entries
                    .iter()
                    .filter(|entry| entry.ordinal == *ordinal)
                {
                    if output.len() == output.capacity() {
                        let grow = 1024;
                        if (output.len() + grow) * size_of::<Entry<N>>() > STAGE_BYTES {
                            return Err("ip_native_cap");
                        }
                        charges.push(budget.reserve(grow * size_of::<Entry<N>>() + 128)?);
                        output.reserve_exact(grow);
                    }
                    output.push(*entry);
                }
            }
        }
        Ok(charges)
    }
}
impl<const N: usize> Tree<N, false> {
    fn collect_range(
        &self,
        low: &[u8; N],
        high: &[u8; N],
        result: &mut RoaringBitmap,
        end: Instant,
    ) -> Result<(), Error> {
        let first = self.leaves.partition_point(|leaf| {
            leaf.entries
                .last()
                .is_some_and(|entry| entry.address < *low)
        });
        for leaf in &self.leaves[first..] {
            check_time(end)?;
            if leaf.entries[0].address > *high {
                break;
            }
            for entry in &leaf.entries {
                if entry.address >= *low && entry.address <= *high {
                    result.insert(entry.ordinal);
                }
            }
        }
        Ok(())
    }
}

pub(super) struct Addresses {
    v4: Arc<Tree<4, false>>,
    r4: Arc<Tree<4, true>>,
    v6: Arc<Tree<16, false>>,
    r6: Arc<Tree<16, true>>,
    has4: Arc<Bitmap>,
    has6: Arc<Bitmap>,
}
impl Addresses {
    pub(super) fn empty(budget: &Arc<Budget>) -> Result<Arc<Self>, Error> {
        Ok(Arc::new(Self {
            v4: Tree::empty(budget)?,
            r4: Tree::empty(budget)?,
            v6: Tree::empty(budget)?,
            r6: Tree::empty(budget)?,
            has4: Bitmap::new(RoaringBitmap::new(), budget)?,
            has6: Bitmap::new(RoaringBitmap::new(), budget)?,
        }))
    }
    pub(super) fn charges(&self) -> impl Iterator<Item = &Charge> + Clone {
        self.v4
            .charges()
            .chain(self.r4.charges())
            .chain(self.v6.charges())
            .chain(self.r6.charges())
            .chain([&self.has4.charge, &self.has6.charge])
    }
    pub(super) fn retiring(&self, sole: bool) -> impl Iterator<Item = &Charge> + Clone {
        self.v4
            .retiring(sole && Arc::strong_count(&self.v4) == 1)
            .chain(self.r4.retiring(sole && Arc::strong_count(&self.r4) == 1))
            .chain(self.v6.retiring(sole && Arc::strong_count(&self.v6) == 1))
            .chain(self.r6.retiring(sole && Arc::strong_count(&self.r6) == 1))
            .chain([&self.has4, &self.has6].into_iter().filter_map(move |set| {
                (sole && Arc::strong_count(set) == 1).then_some(&set.charge)
            }))
    }
    pub(super) fn replace(
        &self,
        changed: &[u32],
        mut added4: Vec<Entry<4>>,
        mut added6: Vec<Entry<16>>,
        budget: &Arc<Budget>,
        max_bytes: usize,
        end: Instant,
    ) -> Result<Arc<Self>, Error> {
        added4.sort_unstable_by(Entry::cmp::<false>);
        added4.dedup();
        added6.sort_unstable_by(Entry::cmp::<false>);
        added6.dedup();
        let mut removed4 = Vec::new();
        let mut removed6 = Vec::new();
        let _old4 = self.r4.previous(changed, &mut removed4, budget, end)?;
        let _old6 = self.r6.previous(changed, &mut removed6, budget, end)?;
        let payload = (self.v4.count - removed4.len() + added4.len()) * 2 * size_of::<Entry<4>>()
            + (self.v6.count - removed6.len() + added6.len()) * 2 * size_of::<Entry<16>>();
        if payload > max_bytes {
            return Err("ip_native_cap");
        }
        let changed_set: RoaringBitmap = changed.iter().copied().collect();
        let refresh = |old: &Arc<Bitmap>, ordinals: &mut dyn Iterator<Item = u32>| {
            let scratch =
                budget.reserve(2 * (old.charge.bytes + bitmap_bytes(&changed_set)) + 4096)?;
            let mut set = old.set.clone();
            for ordinal in changed {
                set.remove(*ordinal);
            }
            set.extend(ordinals);
            if set == old.set {
                Ok(old.clone())
            } else {
                Bitmap::from_reserved(set, scratch)
            }
        };
        let has4 = refresh(&self.has4, &mut added4.iter().map(|entry| entry.ordinal))?;
        let has6 = refresh(&self.has6, &mut added6.iter().map(|entry| entry.ordinal))?;
        let v4 = self.v4.replace(&mut removed4, &mut added4, budget, end)?;
        let r4 = self.r4.replace(&mut removed4, &mut added4, budget, end)?;
        let v6 = self.v6.replace(&mut removed6, &mut added6, budget, end)?;
        let r6 = self.r6.replace(&mut removed6, &mut added6, budget, end)?;
        Ok(Arc::new(Self {
            v4,
            r4,
            v6,
            r6,
            has4,
            has6,
        }))
    }
    pub(super) fn select(
        &self,
        ranges: &[Range],
        budget: &Arc<Budget>,
        end: Instant,
    ) -> Result<Arc<Bitmap>, Error> {
        // A matching result is a subset of the known-family owner universes.
        // Reserve their worst representation before insertion, even for sparse
        // ordinals, then charge the actual output before releasing scratch.
        let scratch =
            budget.reserve(2 * (self.has4.charge.bytes + self.has6.charge.bytes) + 65536)?;
        let mut result = RoaringBitmap::new();
        for range in ranges {
            check_time(end)?;
            if range.family == 4 {
                if range.low == [0; 16] && range.high[12..] == [255; 4] {
                    result |= &self.has4.set;
                } else {
                    self.v4.collect_range(
                        &range.low[12..].try_into().unwrap(),
                        &range.high[12..].try_into().unwrap(),
                        &mut result,
                        end,
                    )?;
                }
            } else if range.low == [0; 16] && range.high == [255; 16] {
                result |= &self.has6.set;
            } else {
                self.v6
                    .collect_range(&range.low, &range.high, &mut result, end)?;
            }
        }
        Bitmap::from_reserved(result, scratch)
    }
}

pub(super) struct Range {
    family: u8,
    low: [u8; 16],
    high: [u8; 16],
}
pub(super) fn ranges(op: u8, bytes: &[u8], prefix: u16) -> Result<Vec<Range>, Error> {
    if op == 8 {
        if !matches!(bytes.len(), 4 | 16) || prefix as usize > bytes.len() * 8 {
            return Err("invalid_expression");
        }
        let mut low = [0; 16];
        let offset = 16 - bytes.len();
        low[offset..].copy_from_slice(bytes);
        let mut high = low;
        for bit in prefix as usize..bytes.len() * 8 {
            low[offset + bit / 8] &= !(1 << (7 - bit % 8));
            high[offset + bit / 8] |= 1 << (7 - bit % 8);
        }
        return Ok(vec![Range {
            family: if bytes.len() == 4 { 4 } else { 6 },
            low,
            high,
        }]);
    }
    if op != 9 || prefix != 0 || bytes.len() % 33 != 0 || bytes.len() / 33 > MAX_RANGES {
        return Err("invalid_expression");
    }
    let mut ranges: Vec<Range> = Vec::with_capacity(bytes.len() / 33);
    for record in bytes.chunks_exact(33) {
        let range = Range {
            family: record[0],
            low: record[1..17].try_into().unwrap(),
            high: record[17..33].try_into().unwrap(),
        };
        if !matches!(range.family, 4 | 6)
            || range.low > range.high
            || (range.family == 4 && (range.low[..12] != [0; 12] || range.high[..12] != [0; 12]))
            || ranges.last().is_some_and(|previous| {
                previous.family > range.family
                    || (previous.family == range.family && previous.high >= range.low)
            })
        {
            return Err("invalid_expression");
        }
        ranges.push(range);
    }
    Ok(ranges)
}

#[cfg(test)]
mod tests {
    use super::super::{Index, Instruction, Kind};

    fn cidr(address: &[u8], bits: u16) -> Instruction {
        (8, String::new(), address.to_vec(), bits)
    }
    fn selected(index: &Index, program: &[Instruction]) -> Vec<u32> {
        index
            .query(b"allowed", program, 1000)
            .unwrap()
            .0
            .page(b"allowed", 0, 128, 1000)
            .unwrap()
    }
    fn index() -> Index {
        Index::new([1; 16], [2; 16], Kind::Device, vec!["vendor".into()]).unwrap()
    }

    #[test]
    fn complete_address_replacement_shares_scalar_revision_and_never_combines_address_bits() {
        let index = index();
        let rows = vec![
            (1, true, vec![("vendor".into(), "A".into())]),
            (u32::MAX, true, vec![]),
            (7, true, vec![]),
        ];
        let stage = index.begin_publish(0, b"first", rows, true).unwrap();
        stage
            .add(
                &[
                    (1, vec![192, 0, 2, 1]),
                    (1, vec![198, 51, 100, 254]),
                    (u32::MAX, vec![192, 0, 2, 1]),
                    (
                        7,
                        vec![0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7],
                    ),
                ],
                &[1, u32::MAX, 7],
            )
            .unwrap();
        assert!(!index.status().unwrap().ready);
        assert!(index.finish_publish(&stage).unwrap().ip_available);
        assert_eq!(
            selected(&index, &[cidr(&[192, 0, 2, 1], 32)]),
            vec![1, u32::MAX]
        );
        assert_eq!(
            selected(&index, &[cidr(&[192, 0, 2, 254], 32)]),
            Vec::<u32>::new()
        );
        assert_eq!(
            selected(&index, &[cidr(&[0, 0, 0, 0], 0)]),
            vec![1, u32::MAX]
        );
        assert_eq!(selected(&index, &[cidr(&[0; 16], 0)]), vec![7]);
        assert_eq!(
            selected(
                &index,
                &[cidr(
                    &[0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7],
                    128
                )]
            ),
            vec![7]
        );
        assert_eq!(
            selected(
                &index,
                &[cidr(&[192, 0, 2, 0], 24), (3, String::new(), vec![], 1)]
            ),
            vec![7]
        );
        let pinned = index
            .query(b"allowed", &[cidr(&[192, 0, 2, 0], 24)], 1000)
            .unwrap()
            .0;
        let stage = index
            .begin_publish(
                1,
                b"second",
                vec![
                    (1, true, vec![("vendor".into(), "B".into())]),
                    (u32::MAX, false, vec![]),
                ],
                true,
            )
            .unwrap();
        stage.add(&[], &[1]).unwrap();
        index.finish_publish(&stage).unwrap();
        assert_eq!(
            pinned.page(b"allowed", 0, 128, 1000).unwrap(),
            vec![1, u32::MAX]
        );
        assert_eq!(
            pinned
                .facets(b"allowed", &[("vendor".into(), "A".into())], 1000)
                .unwrap(),
            vec![1]
        );
        assert!(selected(&index, &[cidr(&[0, 0, 0, 0], 0)]).is_empty());
        assert_eq!(
            selected(&index, &[(0, "vendor".into(), b"B".to_vec(), 0)]),
            vec![1]
        );
        let stage = index
            .begin_publish(
                2,
                b"replay",
                vec![(1, true, vec![("vendor".into(), "B".into())])],
                true,
            )
            .unwrap();
        stage.add(&[], &[1]).unwrap();
        index.finish_publish(&stage).unwrap();
        assert!(selected(&index, &[cidr(&[192, 0, 2, 1], 32)]).is_empty());
        // A named Prefix Tag is one packed range predicate; a shared address
        // keeps every owning device and remains independent of scalar tags.
        let mut range = vec![6];
        range.extend([0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        range.extend([
            0x20, 1, 0x0d, 0xb8, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
        ]);
        assert_eq!(
            selected(&index, &[(9, String::new(), range.clone(), 0)]),
            vec![7]
        );
        range.extend(range.clone());
        assert!(matches!(
            index.query(b"allowed", &[(9, String::new(), range, 0)], 1000),
            Err("invalid_expression")
        ));
        assert!(selected(&index, &[(9, String::new(), vec![], 0)]).is_empty());
    }

    #[test]
    fn incomplete_cancelled_and_unavailable_address_stages_fail_explicitly() {
        let index = index();
        let baseline = index.status().unwrap().native_bytes;
        let stage = index
            .begin_publish(0, b"incomplete", vec![(1, true, vec![])], true)
            .unwrap();
        assert_eq!(
            index.finish_publish(&stage).unwrap_err(),
            "incomplete_addresses"
        );
        stage.abort().unwrap();
        assert_eq!(index.status().unwrap().revision, 0);
        let stage = index
            .begin_publish(0, b"cancelled", vec![(1, true, vec![])], true)
            .unwrap();
        stage.add(&[(1, vec![192, 0, 2, 1])], &[]).unwrap();
        drop(stage);
        assert_eq!(index.status().unwrap().native_bytes, baseline);
        let stage = index
            .begin_publish(0, b"source-cap", vec![(1, true, vec![])], true)
            .unwrap();
        stage.unavailable().unwrap();
        let status = index.finish_publish(&stage).unwrap();
        assert_eq!(status.ip_unavailable_reason, Some("source_cap"));
        assert!(matches!(
            index.query(b"allowed", &[cidr(&[0, 0, 0, 0], 0)], 1000),
            Err("ip_unavailable")
        ));
        let stage = index
            .begin_publish(1, b"later-success", vec![(7, true, vec![])], true)
            .unwrap();
        assert!(!stage.add(&[(7, vec![192, 0, 2, 7])], &[7]).unwrap());
        assert!(!index.finish_publish(&stage).unwrap().ip_available);
        assert_eq!(
            selected(&index, &[(1, String::new(), vec![], 0)]),
            vec![1, 7]
        );
        let stage = index.begin_publish(2, b"closing", vec![], true).unwrap();
        index.close().unwrap();
        assert_eq!(stage.add(&[], &[]), Err("closed"));
    }
}
