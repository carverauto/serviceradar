//! Revision-pinned inventory membership. Coordinates and row offsets never enter this index.
use roaring::RoaringBitmap;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

#[path = "bitmap_pending.rs"]
mod pending;
use pending::Pending;
pub use pending::PendingStatus;

pub type Error = &'static str;
pub type Facet = (String, String);
pub type Row = (u32, bool, Vec<(String, Value)>);
/// Oversized canonical values invalidate their entire facet without stalling inventory.
#[derive(Clone)]
pub enum Value {
    Exact(String),
    Unavailable,
}
impl From<String> for Value {
    fn from(value: String) -> Self {
        if value.len() > 256 {
            Self::Unavailable
        } else {
            Self::Exact(value)
        }
    }
}
impl From<&str> for Value {
    fn from(value: &str) -> Self {
        if value.len() > 256 {
            Self::Unavailable
        } else {
            Self::Exact(value.to_owned())
        }
    }
}
/// Postfix instructions: predicate=0, all=1, any=2, except=3 (one operand).
pub type Instruction = (u8, String, String, u16);
pub const BATCH_LIMIT: usize = 500;
pub const PIN_TTL: Duration = Duration::from_secs(30);
pub enum ViewRow<'a> {
    Leaf(u32),
    Aggregate(&'a [u8]),
}
pub type RowOverlay = (Vec<u8>, Vec<u8>, Vec<u8>, Vec<u8>);
const MAX_VALUES: usize = 4096;
const MAX_FACET_VALUES: usize = 1024;
const MAX_PINS: usize = 128;
const MAX_READERS: usize = 8;
const MAX_BYTES: usize = 200_000_000;
const PEAK_BYTES: usize = 400_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Device,
    Interface,
}

#[derive(Default)]
struct Budget {
    used: AtomicUsize,
    peak: AtomicUsize,
    readers: AtomicUsize,
}
struct Charge {
    budget: Arc<Budget>,
    bytes: usize,
}
impl Budget {
    fn reserve(self: &Arc<Self>, bytes: usize) -> Result<Charge, Error> {
        let previous = self
            .used
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |used| {
                used.checked_add(bytes).filter(|next| *next <= PEAK_BYTES)
            })
            .map_err(|_| "native_memory_budget")?;
        self.peak.fetch_max(previous + bytes, Ordering::Relaxed);
        Ok(Charge {
            budget: self.clone(),
            bytes,
        })
    }
    fn reader(self: &Arc<Self>) -> Result<Reader, Error> {
        self.readers
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < MAX_READERS).then_some(count + 1)
            })
            .map_err(|_| "reader_budget")?;
        Ok(Reader(self.clone()))
    }
}
impl Drop for Charge {
    fn drop(&mut self) {
        self.budget.used.fetch_sub(self.bytes, Ordering::AcqRel);
    }
}
struct Reader(Arc<Budget>);
impl Drop for Reader {
    fn drop(&mut self) {
        self.0.readers.fetch_sub(1, Ordering::AcqRel);
    }
}

struct Bitmap {
    set: RoaringBitmap,
    charge: Charge,
}
fn bitmap_bytes(set: &RoaringBitmap) -> usize {
    let s = set.statistics();
    // Statistics accounts for container capacities. Double the container metadata
    // allowance because Roaring does not expose its outer Vec capacity.
    128 + 128 * s.n_containers as usize
        + (s.n_bytes_array_containers + s.n_bytes_bitset_containers + s.n_bytes_run_containers)
            as usize
}
impl Bitmap {
    fn new(set: RoaringBitmap, budget: &Arc<Budget>) -> Result<Arc<Self>, Error> {
        let charge = budget.reserve(bitmap_bytes(&set))?;
        Ok(Arc::new(Self { set, charge }))
    }
    fn combine(a: &Self, b: &Self, op: u8, budget: &Arc<Budget>) -> Result<Arc<Self>, Error> {
        let scratch = budget.reserve(2 * (a.charge.bytes + b.charge.bytes) + 4096)?;
        let set = match op {
            1 => &a.set & &b.set,
            2 => &a.set | &b.set,
            3 => &a.set - &b.set,
            _ => return Err("invalid_expression"),
        };
        let output = Self::new(set, budget)?;
        drop(scratch);
        Ok(output)
    }
}

struct Revision {
    number: u64,
    fence: u64,
    source: Vec<u8>,
    ready: bool,
    live: Arc<Bitmap>,
    facets: BTreeMap<Facet, Arc<Bitmap>>,
    unavailable: BTreeSet<String>,
    _charge: Charge,
}
struct Pin {
    revision: Arc<Revision>,
    result: Arc<Bitmap>,
    authority: Vec<u8>,
    expires: Instant,
    _charge: Charge,
}
type PinSlot = Mutex<Option<Pin>>;
/// The BEAM owns this handle; expiry also clears the slot through the index's weak registry.
pub struct Query {
    slot: Arc<PinSlot>,
    budget: Arc<Budget>,
    active: Arc<AtomicBool>,
    fence: Arc<AtomicU64>,
    accepted_fence: u64,
    supported: Arc<BTreeSet<String>>,
    dictionary_epoch: [u8; 16],
    index_epoch: [u8; 16],
    kind: Kind,
}
pub struct Index {
    pub dictionary_epoch: [u8; 16],
    pub index_epoch: [u8; 16],
    pub kind: Kind,
    supported: Arc<BTreeSet<String>>,
    active: Arc<AtomicBool>,
    fence: Arc<AtomicU64>,
    revision: Mutex<Arc<Revision>>,
    publisher: Mutex<()>,
    closed: AtomicBool,
    pins: Mutex<Vec<Weak<PinSlot>>>,
    pending: Mutex<Pending>,
    budget: Arc<Budget>,
    _charge: Charge,
}
#[derive(Debug)]
pub struct Status {
    pub revision: u64,
    pub source: Vec<u8>,
    pub ready: bool,
    pub cardinality: u64,
    pub native_bytes: usize,
    pub peak_bytes: usize,
    pub pins: usize,
    pub unavailable: Vec<String>,
    pub pending: PendingStatus,
}

fn deadline(timeout_ms: u64) -> Result<Instant, Error> {
    if !(1..=1000).contains(&timeout_ms) {
        return Err("invalid_deadline");
    }
    Ok(Instant::now() + Duration::from_millis(timeout_ms))
}
fn check_time(end: Instant) -> Result<(), Error> {
    if Instant::now() >= end {
        Err("deadline_exceeded")
    } else {
        Ok(())
    }
}
fn valid_facet(name: &str) -> bool {
    matches!(
        name,
        "vendor" | "region" | "vlan" | "device_class" | "os_name" | "os_version" | "availability"
    ) || name.strip_prefix("tag:").is_some_and(|key| {
        !key.is_empty()
            && key.len() <= 60
            && key
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'.')
    })
}

impl Index {
    pub fn new(
        dictionary_epoch: [u8; 16],
        index_epoch: [u8; 16],
        kind: Kind,
        supported: Vec<String>,
    ) -> Result<Self, Error> {
        if supported.is_empty() || supported.len() > 32 || supported.iter().any(|s| !valid_facet(s))
        {
            return Err("unsupported_facet");
        }
        let budget = Arc::new(Budget::default());
        let charge = budget.reserve(16_384)?;
        let revision = Arc::new(Revision {
            number: 0,
            fence: 0,
            source: Vec::new(),
            ready: false,
            live: Bitmap::new(RoaringBitmap::new(), &budget)?,
            facets: BTreeMap::new(),
            unavailable: BTreeSet::new(),
            _charge: budget.reserve(1024)?,
        });
        Ok(Self {
            dictionary_epoch,
            index_epoch,
            kind,
            supported: Arc::new(supported.into_iter().collect()),
            active: Arc::new(AtomicBool::new(false)),
            fence: Arc::new(AtomicU64::new(0)),
            closed: AtomicBool::new(false),
            revision: Mutex::new(revision),
            publisher: Mutex::new(()),
            pins: Mutex::new(Vec::new()),
            pending: Mutex::new(Pending::new(&budget)?),
            budget,
            _charge: charge,
        })
    }
    pub fn check_identity(&self, dictionary: &[u8], epoch: &[u8], kind: Kind) -> Result<(), Error> {
        if dictionary != self.dictionary_epoch || epoch != self.index_epoch || kind != self.kind {
            return Err("identity_mismatch");
        }
        Ok(())
    }
    fn reap(&self) -> Result<usize, Error> {
        let mut pins = self.pins.try_lock().map_err(|_| "busy")?;
        let now = Instant::now();
        pins.retain(|weak| {
            let Some(slot) = weak.upgrade() else {
                return false;
            };
            let Ok(mut pin) = slot.try_lock() else {
                return true;
            };
            if pin.as_ref().is_some_and(|p| p.expires <= now) {
                *pin = None;
            }
            pin.is_some()
        });
        Ok(pins.len())
    }
    pub fn status(&self) -> Result<Status, Error> {
        let pins = self.reap()?;
        let pending = self.pending.try_lock().map_err(|_| "busy")?.status();
        let revision = self.revision.try_lock().map_err(|_| "busy")?.clone();
        Ok(Status {
            revision: revision.number,
            source: revision.source.clone(),
            ready: revision.ready,
            cardinality: revision.live.set.len(),
            native_bytes: self.budget.used.load(Ordering::Acquire),
            peak_bytes: self.budget.peak.load(Ordering::Relaxed),
            pins,
            unavailable: revision.unavailable.iter().cloned().collect(),
            pending,
        })
    }
    /// Full current rows replace each dirty ordinal; replay is harmless. The caller
    /// serializes source reads and requeues taken hints after any failed publication.
    pub fn publish(
        &self,
        expected: u64,
        source: &[u8],
        rows: Vec<Row>,
        ready: bool,
    ) -> Result<Status, Error> {
        let end = deadline(1000)?;
        let _writer = self.publisher.try_lock().map_err(|_| "publisher_busy")?;
        let pins = self.reap()?;
        let pending = self.pending.try_lock().map_err(|_| "busy")?.status();
        if self.closed.load(Ordering::Acquire) {
            return Err("closed");
        }
        if rows.len() > BATCH_LIMIT || source.is_empty() || source.len() > 128 {
            return Err("batch_budget");
        }
        let old = self.revision.try_lock().map_err(|_| "busy")?.clone();
        if old.number != expected {
            return Err("revision_conflict");
        }
        let mut changed = RoaringBitmap::new();
        let mut additions: BTreeMap<Facet, RoaringBitmap> = BTreeMap::new();
        let mut live_additions = RoaringBitmap::new();
        let mut unavailable = old.unavailable.clone();
        for (id, live, values) in rows {
            if id == 0 || !changed.insert(id) || values.len() > 32 {
                return Err("invalid_row");
            }
            if !live {
                continue;
            }
            live_additions.insert(id);
            let mut seen = BTreeSet::new();
            for (facet, value) in values {
                if !self.supported.contains(&facet) {
                    return Err("invalid_facet_value");
                }
                seen.insert(facet.clone());
                match value {
                    Value::Exact(value) if value.is_empty() => return Err("invalid_facet_value"),
                    Value::Exact(value) if value.len() <= 256 => {
                        additions.entry((facet, value)).or_default().insert(id);
                    }
                    _ => {
                        unavailable.insert(facet);
                    }
                }
            }
            for facet in self.supported.difference(&seen) {
                additions
                    .entry((facet.clone(), "unknown".into()))
                    .or_default()
                    .insert(id);
            }
        }
        let scratch = self.budget.reserve(8 * 1024 * 1024)?;
        let mut keys: BTreeSet<Facet> = old.facets.keys().cloned().collect();
        keys.extend(additions.keys().cloned());
        let mut counts = BTreeMap::new();
        for (facet, _) in &keys {
            *counts.entry(facet.clone()).or_insert(0usize) += 1;
        }
        for (facet, count) in counts {
            if count > MAX_FACET_VALUES {
                unavailable.insert(facet);
            }
        }
        if keys.len() > MAX_VALUES {
            // A cap invalidates complete facets, never just the excess values.
            unavailable.extend(additions.keys().map(|(facet, _)| facet.clone()));
        }
        let mut facets = BTreeMap::new();
        for key in keys {
            check_time(end)?;
            if unavailable.contains(&key.0) {
                continue;
            }
            let before = old.facets.get(&key);
            let add = additions.get(&key);
            if add.is_none() && before.is_some_and(|b| b.set.is_disjoint(&changed)) {
                facets.insert(key, before.unwrap().clone());
                continue;
            }
            let reserve = self
                .budget
                .reserve(before.map_or(0, |b| b.charge.bytes * 2) + 8192)?;
            let mut next = before.map_or_else(RoaringBitmap::new, |b| &b.set - &changed);
            if let Some(add) = add {
                next |= add;
            }
            if !next.is_empty() {
                facets.insert(key, Bitmap::new(next, &self.budget)?);
            }
            drop(reserve);
        }
        let reserve = self.budget.reserve(old.live.charge.bytes * 2 + 8192)?;
        let mut live = &old.live.set - &changed;
        live |= live_additions;
        let metadata = 2048
            + facets
                .keys()
                .map(|(f, v)| 192 + f.capacity() + v.capacity())
                .sum::<usize>();
        let next = Arc::new(Revision {
            number: old.number.checked_add(1).ok_or("revision_exhausted")?,
            source: source.to_vec(),
            fence: self.fence.load(Ordering::Acquire) + u64::from(!ready),
            ready,
            live: Bitmap::new(live, &self.budget)?,
            facets,
            unavailable,
            _charge: self.budget.reserve(metadata)?,
        });
        drop(reserve);
        drop(scratch);
        check_time(end)?;
        if self.budget.used.load(Ordering::Acquire) > MAX_BYTES {
            return Err("native_memory_budget");
        }
        *self.revision.try_lock().map_err(|_| "busy")? = next;
        self.active.store(ready, Ordering::Release);
        if !ready {
            self.fence.fetch_add(1, Ordering::AcqRel);
        }
        drop(old);
        // Publication is committed; status must not turn an acknowledged commit into
        // a busy error merely because another reader is reaping pins.
        let revision = self.revision.lock().map_err(|_| "poisoned")?.clone();
        Ok(Status {
            revision: revision.number,
            source: revision.source.clone(),
            ready: revision.ready,
            cardinality: revision.live.set.len(),
            native_bytes: self.budget.used.load(Ordering::Acquire),
            peak_bytes: self.budget.peak.load(Ordering::Relaxed),
            pins,
            unavailable: revision.unavailable.iter().cloned().collect(),
            pending,
        })
    }
    pub fn close(&self) -> Result<(), Error> {
        let _writer = self.publisher.try_lock().map_err(|_| "publisher_busy")?;
        let mut pending = self.pending.try_lock().map_err(|_| "busy")?;
        pending.clear(&self.budget)?;
        self.closed.store(true, Ordering::Release);
        self.active.store(false, Ordering::Release);
        self.fence.fetch_add(1, Ordering::AcqRel);
        let mut pins = self.pins.try_lock().map_err(|_| "busy")?;
        for weak in pins.iter() {
            if let Some(slot) = weak.upgrade() {
                if let Ok(mut pin) = slot.try_lock() {
                    *pin = None;
                }
            }
        }
        pins.clear();
        let empty = Revision {
            number: 0,
            fence: 0,
            source: Vec::new(),
            ready: false,
            live: Bitmap::new(RoaringBitmap::new(), &self.budget)?,
            facets: BTreeMap::new(),
            unavailable: BTreeSet::new(),
            _charge: self.budget.reserve(1024)?,
        };
        *self.revision.try_lock().map_err(|_| "busy")? = Arc::new(empty);
        Ok(())
    }
    pub fn query(
        &self,
        authority: &[u8],
        program: &[Instruction],
        timeout_ms: u64,
    ) -> Result<(Query, u64, Vec<u8>, u64), Error> {
        let end = deadline(timeout_ms)?;
        let _reader = self.budget.reader()?;
        if authority.is_empty() || authority.len() > 128 {
            return Err("invalid_authority");
        }
        if self.reap()? >= MAX_PINS {
            return Err("pin_budget");
        }
        let revision = self.revision.try_lock().map_err(|_| "busy")?.clone();
        let accepted_fence = revision.fence;
        if !revision.ready {
            return Err("not_ready");
        }
        validate_program(program)?;
        let mut stack: Vec<Arc<Bitmap>> = Vec::new();
        for (opcode, facet, value, arity) in program {
            check_time(end)?;
            if *opcode == 0 {
                if !self.supported.contains(facet) {
                    return Err("unsupported_facet");
                }
                if revision.unavailable.contains(facet) {
                    return Err("facet_unavailable");
                }
                stack.push(match revision.facets.get(&(facet.clone(), value.clone())) {
                    Some(bitmap) => bitmap.clone(),
                    None => Bitmap::new(RoaringBitmap::new(), &self.budget)?,
                });
            } else {
                let operands = stack.split_off(stack.len() - *arity as usize);
                let mut result = if *opcode == 2 {
                    Bitmap::new(RoaringBitmap::new(), &self.budget)?
                } else {
                    revision.live.clone()
                };
                for operand in operands {
                    result = Bitmap::combine(&result, &operand, *opcode, &self.budget)?;
                    check_time(end)?;
                }
                stack.push(result);
            }
        }
        let expression = stack.pop().ok_or("invalid_expression")?;
        let result = Bitmap::combine(&revision.live, &expression, 1, &self.budget)?;
        check_time(end)?;
        if self.budget.used.load(Ordering::Acquire) > MAX_BYTES {
            return Err("native_memory_budget");
        }
        if !self.active.load(Ordering::Acquire)
            || self.fence.load(Ordering::Acquire) != accepted_fence
        {
            return Err("not_ready");
        }
        let total = result.set.len();
        let number = revision.number;
        let source = revision.source.clone();
        let pin = Pin {
            revision,
            result,
            authority: authority.to_vec(),
            expires: Instant::now() + PIN_TTL,
            _charge: self.budget.reserve(512)?,
        };
        let slot = Arc::new(Mutex::new(Some(pin)));
        let mut pins = self.pins.try_lock().map_err(|_| "busy")?;
        if pins.len() >= MAX_PINS {
            return Err("pin_budget");
        }
        pins.push(Arc::downgrade(&slot));
        Ok((
            Query {
                slot,
                budget: self.budget.clone(),
                active: self.active.clone(),
                fence: self.fence.clone(),
                accepted_fence,
                supported: self.supported.clone(),
                dictionary_epoch: self.dictionary_epoch,
                index_epoch: self.index_epoch,
                kind: self.kind,
            },
            number,
            source,
            total,
        ))
    }
}

fn validate_program(program: &[Instruction]) -> Result<(), Error> {
    if program.is_empty() || program.len() > 65 {
        return Err("expression_budget");
    }
    let mut depths = Vec::new();
    let mut predicates = 0;
    let mut bytes = 0;
    for (op, facet, value, arity) in program {
        bytes += facet.len() + value.len() + 8;
        if *op == 0 {
            predicates += 1;
            if *arity != 0
                || facet.is_empty()
                || facet.len() > 64
                || value.is_empty()
                || value.len() > 256
            {
                return Err("invalid_expression");
            }
            depths.push(1usize);
        } else {
            if !(1..=3).contains(op)
                || (*op == 3 && *arity != 1)
                || !facet.is_empty()
                || !value.is_empty()
                || *arity as usize > depths.len()
            {
                return Err("invalid_expression");
            }
            let children = depths.split_off(depths.len() - *arity as usize);
            let depth = 1 + children.into_iter().max().unwrap_or(0);
            if depth > 8 {
                return Err("expression_budget");
            }
            depths.push(depth);
        }
    }
    if depths.len() != 1 || predicates > 32 || bytes > 16384 {
        return Err("expression_budget");
    }
    Ok(())
}

impl Query {
    fn with_pin<T>(
        &self,
        authority: &[u8],
        timeout_ms: u64,
        f: impl FnOnce(&Pin, Instant) -> Result<T, Error>,
    ) -> Result<T, Error> {
        let end = deadline(timeout_ms)?;
        if !self.active.load(Ordering::Acquire)
            || self.fence.load(Ordering::Acquire) != self.accepted_fence
        {
            return Err("not_ready");
        }
        let _reader = self.budget.reader()?;
        let mut slot = self.slot.try_lock().map_err(|_| "busy")?;
        if slot
            .as_ref()
            .is_some_and(|pin| pin.expires <= Instant::now())
        {
            *slot = None;
        }
        let pin = slot.as_ref().ok_or("restart_required")?;
        if authority != pin.authority {
            return Err("authority_mismatch");
        }
        let output = f(pin, end)?;
        check_time(end)?;
        if !self.active.load(Ordering::Acquire)
            || self.fence.load(Ordering::Acquire) != self.accepted_fence
        {
            *slot = None;
            return Err("not_ready");
        }
        Ok(output)
    }
    pub fn page(
        &self,
        authority: &[u8],
        after: u32,
        limit: usize,
        timeout_ms: u64,
    ) -> Result<Vec<u32>, Error> {
        if !(1..=128).contains(&limit) {
            return Err("page_budget");
        }
        self.with_pin(authority, timeout_ms, |pin, _| {
            Ok(after.checked_add(1).map_or_else(Vec::new, |start| {
                pin.result.set.range(start..).take(limit).collect()
            }))
        })
    }
    pub fn facets(
        &self,
        authority: &[u8],
        facets: &[Facet],
        timeout_ms: u64,
    ) -> Result<Vec<u64>, Error> {
        if facets.len() > 50 {
            return Err("facet_budget");
        }
        self.with_pin(authority, timeout_ms, |pin, end| {
            facets
                .iter()
                .map(|key| {
                    check_time(end)?;
                    if !self.supported.contains(&key.0) {
                        return Err("unsupported_facet");
                    }
                    if key.1.is_empty() || key.1.len() > 256 {
                        return Err("invalid_facet_value");
                    }
                    if pin.revision.unavailable.contains(&key.0) {
                        return Err("facet_unavailable");
                    }
                    Ok(pin
                        .revision
                        .facets
                        .get(key)
                        .map_or(0, |facet| pin.result.set.intersection_len(&facet.set)))
                })
                .collect()
        })
    }
    pub fn count_serialized(
        &self,
        authority: &[u8],
        dictionary: &[u8],
        epoch: &[u8],
        kind: Kind,
        bytes: &[u8],
        timeout_ms: u64,
    ) -> Result<u64, Error> {
        if dictionary != self.dictionary_epoch || epoch != self.index_epoch || kind != self.kind {
            return Err("identity_mismatch");
        }
        if bytes.len() > 8 * 1024 * 1024 {
            return Err("bitmap_budget");
        }
        self.with_pin(authority, timeout_ms, |pin, end| {
            // Checked portable decoding can hold container descriptions plus input
            // and output buffers. Reserve worst-case bounded scratch before decoding.
            let _scratch = self.budget.reserve(64 * 1024 * 1024)?;
            let bitmap = deserialize_bitmap(bytes)?;
            check_time(end)?;
            Ok(pin.result.set.intersection_len(&bitmap))
        })
    }
    /// Complete admitted-row columns: matching u8, causal u8, availability u8,
    /// matched-device count LE-u32. The caller binds this order to its tile receipt.
    pub fn row_overlay(
        &self,
        authority: &[u8],
        dictionary: &[u8],
        epoch: &[u8],
        kind: Kind,
        rows: &[ViewRow<'_>],
        timeout_ms: u64,
    ) -> Result<RowOverlay, Error> {
        if dictionary != self.dictionary_epoch
            || epoch != self.index_epoch
            || kind != self.kind
            || kind != Kind::Device
        {
            return Err("identity_mismatch");
        }
        let input_bytes = rows
            .iter()
            .try_fold(0usize, |sum, row| {
                sum.checked_add(match row {
                    ViewRow::Leaf(_) => 0,
                    ViewRow::Aggregate(bytes) => bytes.len(),
                })
            })
            .ok_or("bitmap_budget")?;
        if rows.len() > 128 || input_bytes > 8 * 1024 * 1024 {
            return Err("bitmap_budget");
        }
        self.with_pin(authority, timeout_ms, |pin, end| {
            let _scratch = self.budget.reserve(if input_bytes == 0 {
                4096
            } else {
                64 * 1024 * 1024
            })?;
            let mut mask = Vec::with_capacity(rows.len());
            let mut availability = Vec::with_capacity(rows.len());
            let mut counts = Vec::with_capacity(rows.len() * 4);
            let availability_supported = self.supported.contains("availability")
                && !pin.revision.unavailable.contains("availability");
            let healthy = pin
                .revision
                .facets
                .get(&("availability".into(), "healthy".into()));
            let unavailable = pin
                .revision
                .facets
                .get(&("availability".into(), "unavailable".into()));
            for row in rows {
                check_time(end)?;
                let (count, healthy_count, unavailable_count) = match row {
                    ViewRow::Leaf(0) => (0, 0, 0),
                    ViewRow::Leaf(id) => {
                        let count = u64::from(pin.result.set.contains(*id));
                        (
                            count,
                            count * u64::from(healthy.is_some_and(|set| set.set.contains(*id))),
                            count * u64::from(unavailable.is_some_and(|set| set.set.contains(*id))),
                        )
                    }
                    ViewRow::Aggregate(bytes) => {
                        let members = deserialize_bitmap(bytes)? & &pin.result.set;
                        check_time(end)?;
                        (
                            members.len(),
                            healthy.map_or(0, |set| members.intersection_len(&set.set)),
                            unavailable.map_or(0, |set| members.intersection_len(&set.set)),
                        )
                    }
                };
                mask.push(u8::from(count > 0));
                availability.push(
                    if availability_supported && count > 0 && healthy_count == count {
                        0
                    } else if availability_supported && count > 0 && unavailable_count == count {
                        1
                    } else {
                        2
                    },
                );
                counts.extend_from_slice(
                    &u32::try_from(count)
                        .map_err(|_| "bitmap_budget")?
                        .to_le_bytes(),
                );
            }
            // There is no canonical fleet-wide causal producer; availability is independent.
            Ok((mask, vec![3; rows.len()], availability, counts))
        })
    }
    pub fn close(&self) -> Result<(), Error> {
        *self.slot.try_lock().map_err(|_| "busy")? = None;
        Ok(())
    }
}

fn deserialize_bitmap(bytes: &[u8]) -> Result<RoaringBitmap, Error> {
    let mut cursor = std::io::Cursor::new(bytes);
    let bitmap = RoaringBitmap::deserialize_from(&mut cursor).map_err(|_| "invalid_bitmap")?;
    if cursor.position() != bytes.len() as u64 || bitmap.contains(0) {
        return Err("invalid_bitmap");
    }
    Ok(bitmap)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn index() -> Index {
        Index::new(
            [1; 16],
            [2; 16],
            Kind::Device,
            vec!["vendor".into(), "availability".into()],
        )
        .unwrap()
    }
    fn row(id: u32, vendor: &str, available: &str) -> Row {
        (
            id,
            true,
            vec![
                ("vendor".into(), vendor.into()),
                ("availability".into(), available.into()),
            ],
        )
    }
    fn predicate(facet: &str, value: &str) -> Instruction {
        (0, facet.into(), value.into(), 0)
    }
    fn operator(code: u8, arity: u16) -> Instruction {
        (code, String::new(), String::new(), arity)
    }
    fn all(index: &Index) -> Query {
        index.query(b"allow", &[operator(1, 0)], 1000).unwrap().0
    }

    #[test]
    fn row_overlays_use_one_revision_and_exact_homogeneous_matched_availability() {
        let index = index();
        index
            .publish(
                0,
                b"seed",
                vec![
                    row(1, "Example A", "healthy"),
                    row(2, "Example A", "unavailable"),
                    row(u32::MAX, "Example A", "unknown"),
                    row(4, "Example B", "unavailable"),
                ],
                true,
            )
            .unwrap();
        let query = index
            .query(b"allow", &[predicate("vendor", "Example A")], 1000)
            .unwrap()
            .0;
        let serialize = |ids: &[u32]| {
            let bitmap: RoaringBitmap = ids.iter().copied().collect();
            let mut bytes = Vec::new();
            bitmap.serialize_into(&mut bytes).unwrap();
            bytes
        };
        let mixed = serialize(&[1, 2, u32::MAX]);
        let filtered_healthy = serialize(&[1, 4]);
        let nonmatching = serialize(&[4]);
        let rows = [
            ViewRow::Leaf(0),
            ViewRow::Leaf(1),
            ViewRow::Leaf(2),
            ViewRow::Leaf(u32::MAX),
            ViewRow::Aggregate(&mixed),
            ViewRow::Aggregate(&filtered_healthy),
            ViewRow::Aggregate(&nonmatching),
        ];
        index
            .publish(
                1,
                b"changed",
                vec![row(1, "Example A", "unavailable"), (2, false, vec![])],
                true,
            )
            .unwrap();
        let (mask, causal, availability, counts) = query
            .row_overlay(b"allow", &[1; 16], &[2; 16], Kind::Device, &rows, 1000)
            .unwrap();
        assert_eq!(mask, [0, 1, 1, 1, 1, 1, 0]);
        assert_eq!(causal, [3; 7]);
        assert_eq!(availability, [2, 0, 1, 2, 2, 0, 2]);
        assert_eq!(
            counts
                .chunks_exact(4)
                .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
                .collect::<Vec<_>>(),
            [0, 1, 1, 1, 3, 1, 0]
        );
        assert_eq!(
            query.row_overlay(b"allow", &[9; 16], &[2; 16], Kind::Device, &rows, 1000),
            Err("identity_mismatch")
        );
        assert_eq!(
            query.row_overlay(b"revoked", &[1; 16], &[2; 16], Kind::Device, &rows, 1000),
            Err("authority_mismatch")
        );
        assert_eq!(
            query.row_overlay(
                b"allow",
                &[1; 16],
                &[2; 16],
                Kind::Device,
                &[ViewRow::Aggregate(&serialize(&[0]))],
                1000
            ),
            Err("invalid_bitmap")
        );
        let excessive: Vec<_> = (0..129).map(ViewRow::Leaf).collect();
        assert_eq!(
            query.row_overlay(b"allow", &[1; 16], &[2; 16], Kind::Device, &excessive, 1000),
            Err("bitmap_budget")
        );
        let huge = vec![0; 8 * 1024 * 1024 + 1];
        assert_eq!(
            query.row_overlay(
                b"allow",
                &[1; 16],
                &[2; 16],
                Kind::Device,
                &[ViewRow::Aggregate(&huge)],
                1000
            ),
            Err("bitmap_budget")
        );
    }

    #[test]
    fn coherent_replay_delete_restore_and_pinned_unsigned_pages() {
        let index = index();
        assert!(matches!(
            index.query(b"allow", &[operator(1, 0)], 1000),
            Err("not_ready")
        ));
        let rows = vec![
            row(7, "Example A", "healthy"),
            row(2_147_483_649, "Example B", "unknown"),
            row(u32::MAX, "Example A", "unavailable"),
        ];
        index.publish(0, b"seed", rows.clone(), true).unwrap();
        let old = all(&index);
        assert_eq!(
            old.page(b"allow", 0, 2, 1000).unwrap(),
            vec![7, 2_147_483_649]
        );
        assert_eq!(
            old.page(b"allow", 2_147_483_649, 2, 1000).unwrap(),
            vec![u32::MAX]
        );
        assert!(old.page(b"allow", u32::MAX, 2, 1000).unwrap().is_empty());
        index.publish(1, b"replay", rows, true).unwrap();
        assert_eq!(index.status().unwrap().cardinality, 3);
        index
            .publish(2, b"delete", vec![(7, false, vec![])], true)
            .unwrap();
        assert_eq!(
            all(&index).page(b"allow", 0, 128, 1000).unwrap(),
            vec![2_147_483_649, u32::MAX]
        );
        assert_eq!(
            old.page(b"allow", 0, 128, 1000).unwrap(),
            vec![7, 2_147_483_649, u32::MAX]
        );
        index
            .publish(3, b"restore", vec![row(7, "Example B", "healthy")], true)
            .unwrap();
        assert_eq!(
            all(&index)
                .facets(b"allow", &[("vendor".into(), "Example B".into())], 1000)
                .unwrap(),
            vec![2]
        );
        assert_eq!(
            index.publish(2, b"stale", vec![], true).unwrap_err(),
            "revision_conflict"
        );
        assert_eq!(index.status().unwrap().revision, 4);
    }

    #[test]
    fn query_matches_independent_reference_and_conjunctive_facets() {
        let index = index();
        let rows: Vec<_> = (1..=500)
            .map(|id| {
                row(
                    id,
                    if id % 3 == 0 {
                        "Example A"
                    } else {
                        "Example B"
                    },
                    if id % 5 == 0 {
                        "unavailable"
                    } else {
                        "healthy"
                    },
                )
            })
            .collect();
        index.publish(0, b"seed", rows, true).unwrap();
        let program = [
            predicate("vendor", "Example A"),
            predicate("availability", "unavailable"),
            operator(3, 1),
            operator(1, 2),
        ];
        let (query, revision, source, total) = index.query(b"allow", &program, 1000).unwrap();
        let expected: Vec<_> = (1..=500).filter(|id| id % 3 == 0 && id % 5 != 0).collect();
        assert_eq!(revision, 1);
        assert_eq!(source, b"seed");
        assert_eq!(total, expected.len() as u64);
        let first = query.page(b"allow", 0, 128, 1000).unwrap();
        let second = query
            .page(b"allow", *first.last().unwrap(), 128, 1000)
            .unwrap();
        assert_eq!([first, second].concat(), expected);
        assert_eq!(
            query
                .facets(
                    b"allow",
                    &[
                        ("vendor".into(), "Example A".into()),
                        ("vendor".into(), "Example B".into())
                    ],
                    1000
                )
                .unwrap(),
            vec![total, 0]
        );
        let none = index
            .query(b"allow", &[predicate("vendor", "absent")], 1000)
            .unwrap();
        assert_eq!(none.3, 0);
        assert_eq!(
            none.0
                .facets(b"allow", &[("vendor".into(), "Example A".into())], 1000)
                .unwrap(),
            vec![0]
        );
        let either = index
            .query(
                b"allow",
                &[
                    predicate("vendor", "Example A"),
                    predicate("vendor", "Example B"),
                    operator(2, 2),
                ],
                1000,
            )
            .unwrap();
        assert_eq!(either.3, 500);
    }

    #[test]
    fn identities_authority_and_unavailable_facets_fail_closed() {
        let index = index();
        index
            .publish(0, b"seed", vec![row(1, "Example A", "healthy")], true)
            .unwrap();
        assert_eq!(
            index.check_identity(&[9; 16], &[2; 16], Kind::Device),
            Err("identity_mismatch")
        );
        assert_eq!(
            index.check_identity(&[1; 16], &[9; 16], Kind::Device),
            Err("identity_mismatch")
        );
        assert_eq!(
            index.check_identity(&[1; 16], &[2; 16], Kind::Interface),
            Err("identity_mismatch")
        );
        let query = all(&index);
        assert_eq!(
            query.page(b"revoked", 0, 1, 1000),
            Err("authority_mismatch")
        );
        assert_eq!(
            query.facets(b"allow", &[("causal".into(), "healthy".into())], 1000),
            Err("unsupported_facet")
        );
        assert!(matches!(
            index.query(b"allow", &[predicate("causal", "healthy")], 1000),
            Err("unsupported_facet")
        ));
        for batch in 0..3 {
            let revision = index.status().unwrap().revision;
            let rows = (1..=500)
                .map(|n| {
                    let id = 2 + batch * 500 + n;
                    row(id, &format!("invented-{id}"), "healthy")
                })
                .collect();
            index.publish(revision, b"cardinality", rows, true).unwrap();
        }
        assert_eq!(index.status().unwrap().unavailable, vec!["vendor"]);
        assert!(matches!(
            index.query(b"allow", &[predicate("vendor", "Example A")], 1000),
            Err("facet_unavailable")
        ));
        assert_eq!(
            all(&index)
                .facets(b"allow", &[("availability".into(), "healthy".into())], 1000)
                .unwrap(),
            vec![1501]
        );
        let revision = index.status().unwrap().revision;
        index
            .publish(revision, b"retention_fence", vec![], false)
            .unwrap();
        assert_eq!(query.page(b"allow", 0, 1, 1000), Err("not_ready"));
        index
            .publish(revision + 1, b"reseed", vec![], true)
            .unwrap();
        assert_eq!(query.page(b"allow", 0, 1, 1000), Err("not_ready"));
        let accepted = all(&index);
        index.close().unwrap();
        assert_eq!(accepted.page(b"allow", 0, 1, 1000), Err("not_ready"));
        assert_eq!(index.status().unwrap().cardinality, 0);
        assert_eq!(
            index.publish(0, b"closed", vec![], true).unwrap_err(),
            "closed"
        );
    }

    #[test]
    fn checked_portable_intersection_and_query_lifetimes() {
        let index = index();
        index
            .publish(
                0,
                b"seed",
                vec![
                    row(1, "Example A", "healthy"),
                    row(u32::MAX, "Example B", "unknown"),
                ],
                true,
            )
            .unwrap();
        let query = all(&index);
        let members: RoaringBitmap = [2, u32::MAX].into_iter().collect();
        let mut bytes = Vec::new();
        members.serialize_into(&mut bytes).unwrap();
        assert_eq!(
            query.count_serialized(b"allow", &[1; 16], &[2; 16], Kind::Device, &bytes, 1000),
            Ok(1)
        );
        bytes.push(0);
        assert_eq!(
            query.count_serialized(b"allow", &[1; 16], &[2; 16], Kind::Device, &bytes, 1000),
            Err("invalid_bitmap")
        );
        query.close().unwrap();
        assert_eq!(query.page(b"allow", 0, 1, 1000), Err("restart_required"));
        let expired = all(&index);
        expired.slot.lock().unwrap().as_mut().unwrap().expires =
            Instant::now() - Duration::from_millis(1);
        assert_eq!(index.status().unwrap().pins, 0);
        assert_eq!(expired.page(b"allow", 0, 1, 1000), Err("restart_required"));
        let pins: Vec<_> = (0..128).map(|_| all(&index)).collect();
        assert!(matches!(
            index.query(b"allow", &[operator(1, 0)], 1000),
            Err("pin_budget")
        ));
        drop(pins);
        assert_eq!(index.status().unwrap().pins, 0);
    }

    #[test]
    fn malformed_and_excessive_work_cannot_partially_publish() {
        let index = index();
        assert_eq!(
            index
                .publish(0, b"seed", vec![row(0, "A", "healthy")], true)
                .unwrap_err(),
            "invalid_row"
        );
        assert_eq!(
            index
                .publish(
                    0,
                    b"seed",
                    vec![row(1, "A", "healthy"), row(1, "B", "healthy")],
                    true
                )
                .unwrap_err(),
            "invalid_row"
        );
        assert_eq!(index.status().unwrap().revision, 0);
        index
            .publish(0, b"seed", vec![row(1, "A", "healthy")], true)
            .unwrap();
        for program in [
            vec![operator(1, 1)],
            vec![operator(3, 0)],
            vec![predicate("vendor", "A"); 33],
        ] {
            assert!(index.query(b"allow", &program, 1000).is_err());
        }
        let deep: Vec<_> = std::iter::once(predicate("vendor", "A"))
            .chain(std::iter::repeat_n(operator(3, 1), 8))
            .collect();
        assert!(matches!(
            index.query(b"allow", &deep, 1000),
            Err("expression_budget")
        ));
        assert!(matches!(
            index.query(b"allow", &[operator(1, 0)], 1001),
            Err("invalid_deadline")
        ));
        let guards: Vec<_> = (0..8).map(|_| index.budget.reader().unwrap()).collect();
        assert!(matches!(
            index.query(b"allow", &[operator(1, 0)], 1000),
            Err("reader_budget")
        ));
        drop(guards);
        let reservation = index
            .budget
            .reserve(PEAK_BYTES - index.budget.used.load(Ordering::Acquire))
            .unwrap();
        assert!(matches!(
            index.query(b"allow", &[operator(1, 0)], 1000),
            Err("native_memory_budget")
        ));
        drop(reservation);
        assert_eq!(index.status().unwrap().cardinality, 1);
    }
}
