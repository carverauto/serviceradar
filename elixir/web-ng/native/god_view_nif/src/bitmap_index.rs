//! Revision-pinned inventory membership. Coordinates and row offsets never enter this index.
use roaring::RoaringBitmap;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

#[path = "bitmap_addresses.rs"]
mod addresses;
#[path = "bitmap_facets.rs"]
mod facets;
#[path = "bitmap_pending.rs"]
mod pending;
#[path = "bitmap_staging.rs"]
mod staging;
use addresses::{Addresses, Entry};
use facets::Presence;
use pending::Pending;
pub use pending::PendingStatus;
pub use staging::Stage;

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
/// Postfix predicates and boolean operators. Values remain binary at the NIF boundary.
pub type Instruction = (u8, String, Vec<u8>, u16);
pub const BATCH_LIMIT: usize = 500;
pub const PIN_TTL: Duration = Duration::from_secs(30);
pub enum ViewRow<'a> {
    Leaf(u32),
    Aggregate(&'a [u8]),
}
pub type RowOverlay = (Vec<u8>, Vec<u8>, Vec<u8>, Vec<u8>);
const MAX_VALUES: usize = 4096;
const MAX_FACET_VALUES: usize = 1024;
const MAX_PINS: usize = 8;
const MAX_READERS: usize = 8;
// One owner index, two 32 MiB Atlas mappings, and a deployment-wide 4 MiB
// Prefix Tags catalog remain below 200 MB retained. Export scratch, BEAM
// buffers and existing world geometry are separate from this index budget.
const MAX_BYTES: usize = 125_000_000;
const PEAK_BYTES: usize = 160_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Device,
    Interface,
}

#[derive(Default)]
struct Budget {
    used: AtomicUsize,
    retained: AtomicUsize,
    admission: Mutex<()>,
    peak: AtomicUsize,
    readers: AtomicUsize,
}
struct Charge {
    budget: Arc<Budget>,
    bytes: usize,
    retained: AtomicBool,
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
            retained: AtomicBool::new(false),
        })
    }
    // Only published revisions, accepted pins and the pending queue are steady
    // allocations. Scratch and unfinished expressions remain transient. Serialize
    // ownership transitions so concurrent admissions cannot oversubscribe steady
    // memory; retirement is allowed only with the owner's lock and sole ownership.
    fn admit<'a>(
        &self,
        additions: impl Iterator<Item = &'a Charge> + Clone,
        retired: impl Iterator<Item = &'a Charge> + Clone,
    ) -> Result<(), Error> {
        let _admission = self.admission.try_lock().map_err(|_| "busy")?;
        let added: usize = additions
            .clone()
            .filter(|charge| !charge.retained.load(Ordering::Acquire))
            .map(|charge| charge.bytes)
            .sum();
        let removed: usize = retired
            .clone()
            .filter(|charge| charge.retained.load(Ordering::Acquire))
            .map(|charge| charge.bytes)
            .sum();
        if self.retained.load(Ordering::Acquire) + added - removed > MAX_BYTES {
            return Err("native_memory_budget");
        }
        for charge in retired {
            if charge.retained.swap(false, Ordering::AcqRel) {
                self.retained.fetch_sub(charge.bytes, Ordering::AcqRel);
            }
        }
        for charge in additions {
            if !charge.retained.swap(true, Ordering::AcqRel) {
                self.retained.fetch_add(charge.bytes, Ordering::AcqRel);
            }
        }
        Ok(())
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
        if self.retained.load(Ordering::Acquire) {
            self.budget.retained.fetch_sub(self.bytes, Ordering::AcqRel);
        }
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
    // roaring 0.11.4's "bytes" bitset statistic reports bit capacity: each
    // Box<[u64; 1024]> is 8192 bytes, not 65536. The array statistic counts
    // Vec<u16> capacity with sizeof(u32); retain that conservative allowance.
    // Double container metadata because the outer Vec capacity is not exposed.
    128 + 128 * s.n_containers as usize
        + s.n_bytes_array_containers as usize
        + 8192 * s.n_bitset_containers as usize
        + s.n_bytes_run_containers as usize
}
impl Bitmap {
    fn new(set: RoaringBitmap, budget: &Arc<Budget>) -> Result<Arc<Self>, Error> {
        let charge = budget.reserve(bitmap_bytes(&set))?;
        Ok(Arc::new(Self { set, charge }))
    }
    fn from_reserved(set: RoaringBitmap, mut charge: Charge) -> Result<Arc<Self>, Error> {
        let bytes = bitmap_bytes(&set);
        if bytes > charge.bytes {
            return Err("reservation_too_small");
        }
        // The completed set occupies the memory already reserved for computing
        // it. Transfer that allocation's ownership instead of reserving it twice.
        charge
            .budget
            .used
            .fetch_sub(charge.bytes - bytes, Ordering::AcqRel);
        charge.bytes = bytes;
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
        Self::from_reserved(set, scratch)
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
    presence: BTreeMap<String, Presence>,
    addresses: Option<Arc<Addresses>>,
    ip_unavailable: Option<&'static str>,
    _charge: Charge,
}
impl Revision {
    fn charges(&self) -> impl Iterator<Item = &Charge> + Clone {
        std::iter::once(&self._charge)
            .chain(std::iter::once(&self.live.charge))
            .chain(self.facets.values().map(|bitmap| &bitmap.charge))
            .chain(self.presence.values().filter_map(Presence::charge))
            .chain(
                self.addresses
                    .iter()
                    .flat_map(|addresses| addresses.charges()),
            )
    }
    fn retiring_charges(&self, sole_revision: bool) -> impl Iterator<Item = &Charge> + Clone {
        std::iter::once(&self._charge)
            .filter(move |_| sole_revision)
            .chain(
                std::iter::once(&self.live)
                    .chain(self.facets.values())
                    .chain(self.presence.values().filter_map(Presence::subset))
                    .filter(move |bitmap| sole_revision && Arc::strong_count(bitmap) == 1)
                    .map(|bitmap| &bitmap.charge),
            )
            .chain(self.addresses.iter().flat_map(move |addresses| {
                addresses.retiring(sole_revision && Arc::strong_count(addresses) == 1)
            }))
    }
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
    closed: Arc<AtomicBool>,
    pins: Mutex<Vec<Weak<PinSlot>>>,
    pending: Mutex<Pending>,
    stage: Mutex<Option<Weak<staging::StageSlot>>>,
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
    pub ip_available: bool,
    pub ip_unavailable_reason: Option<&'static str>,
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
    ) || name
        .strip_prefix("tag:")
        .is_some_and(|key| (1..=60).contains(&key.len()))
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
            presence: supported
                .iter()
                .cloned()
                .map(|key| (key, Presence::AllLive))
                .collect(),
            addresses: None,
            ip_unavailable: None,
            _charge: budget.reserve(8192)?,
        });
        budget.admit(
            revision.charges().chain(std::iter::once(&charge)),
            std::iter::empty(),
        )?;
        Ok(Self {
            dictionary_epoch,
            index_epoch,
            kind,
            supported: Arc::new(supported.into_iter().collect()),
            active: Arc::new(AtomicBool::new(false)),
            fence: Arc::new(AtomicU64::new(0)),
            closed: Arc::new(AtomicBool::new(false)),
            revision: Mutex::new(revision),
            publisher: Mutex::new(()),
            pins: Mutex::new(Vec::new()),
            pending: Mutex::new(Pending::new(&budget)?),
            stage: Mutex::new(None),
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
            ready: revision.ready && !self.closed.load(Ordering::Acquire),
            cardinality: revision.live.set.len(),
            native_bytes: self.budget.used.load(Ordering::Acquire),
            peak_bytes: self.budget.peak.load(Ordering::Relaxed),
            pins,
            unavailable: revision.unavailable.iter().cloned().collect(),
            pending,
            ip_available: revision.addresses.is_some(),
            ip_unavailable_reason: revision.ip_unavailable,
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
        self.publish_complete(expected, source, rows, ready, None)
    }
    fn publish_complete(
        &self,
        expected: u64,
        source: &[u8],
        rows: Vec<Row>,
        ready: bool,
        address_update: Option<(Vec<Entry<4>>, Vec<Entry<16>>, Option<&'static str>)>,
    ) -> Result<Status, Error> {
        let end = deadline(1000)?;
        let _writer = self.publisher.try_lock().map_err(|_| "publisher_busy")?;
        let pins = self.reap()?;
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
        let mut present = BTreeMap::<String, RoaringBitmap>::new();
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
                if !seen.insert(facet.clone()) {
                    return Err("invalid_row");
                }
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
            for facet in &seen {
                present.entry(facet.clone()).or_default().insert(id);
            }
            for facet in self.supported.difference(&seen) {
                additions
                    .entry((facet.clone(), "unknown".into()))
                    .or_default()
                    .insert(id);
            }
        }
        let scratch = self.budget.reserve(8 * 1024 * 1024)?;
        let mut candidates: Vec<Facet> = old.facets.keys().cloned().collect();
        for key in additions.keys() {
            if !old.facets.contains_key(key) {
                candidates.push(key.clone());
            }
        }
        let mut keys = BTreeSet::new();
        for key in candidates {
            check_time(end)?;
            if unavailable.contains(&key.0) {
                continue;
            }
            let nonempty = match (old.facets.get(&key), additions.get(&key)) {
                (_, Some(_)) => true,
                (Some(before), None) => !before.set.is_subset(&changed),
                (None, None) => false,
            };
            if nonempty {
                keys.insert(key);
            }
        }
        let mut counts = BTreeMap::new();
        for (facet, _) in &keys {
            *counts.entry(facet.clone()).or_insert(0usize) += 1;
        }
        for (facet, count) in counts {
            if count > MAX_FACET_VALUES {
                unavailable.insert(facet);
            }
        }
        keys.retain(|(facet, _)| !unavailable.contains(facet));
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
            let unchanged = match (before, add) {
                (Some(before), Some(add)) => {
                    add.is_subset(&before.set) && before.set.intersection_len(&changed) == add.len()
                }
                (Some(before), None) => before.set.is_disjoint(&changed),
                _ => false,
            };
            if unchanged {
                facets.insert(key, before.unwrap().clone());
                continue;
            }
            let reserve = self.budget.reserve(
                2 * (before.map_or(0, |b| b.charge.bytes) + add.map_or(0, bitmap_bytes)) + 4096,
            )?;
            let mut next = before.map_or_else(RoaringBitmap::new, |b| &b.set - &changed);
            if let Some(add) = add {
                next |= add;
            }
            if !next.is_empty() {
                facets.insert(key, Bitmap::from_reserved(next, reserve)?);
            }
        }
        let live = if live_additions.is_subset(&old.live.set)
            && old.live.set.intersection_len(&changed) == live_additions.len()
        {
            old.live.clone()
        } else {
            let reserve = self
                .budget
                .reserve(2 * (old.live.charge.bytes + bitmap_bytes(&live_additions)) + 4096)?;
            let mut live = &old.live.set - &changed;
            live |= live_additions;
            Bitmap::from_reserved(live, reserve)?
        };
        let presence =
            facets::refresh_presence(&old, &live, &changed, &present, &self.budget, end)?;
        let metadata = 8192
            + facets
                .keys()
                .map(|(f, v)| 192 + f.capacity() + v.capacity())
                .sum::<usize>();
        let retained_budget = MAX_BYTES.saturating_sub(
            self._charge.bytes
                + live.charge.bytes
                + facets.values().map(|set| set.charge.bytes).sum::<usize>()
                + presence
                    .values()
                    .filter_map(Presence::charge)
                    .map(|charge| charge.bytes)
                    .sum::<usize>()
                + metadata,
        );
        let (addresses, ip_unavailable) = match (old.ip_unavailable, address_update) {
            (Some(reason), _) => (None, Some(reason)),
            (None, Some((_, _, Some(reason)))) => (None, Some(reason)),
            (None, Some((added4, added6, None)))
                if old.addresses.is_some() || live.set.is_subset(&changed) =>
            {
                let before = match &old.addresses {
                    Some(addresses) => addresses.clone(),
                    None => Addresses::empty(&self.budget)?,
                };
                match before.replace(
                    &changed.iter().collect::<Vec<_>>(),
                    added4,
                    added6,
                    &self.budget,
                    retained_budget,
                    end,
                ) {
                    Ok(addresses) => (Some(addresses), None),
                    Err("ip_native_cap") => (None, Some("native_cap")),
                    Err(error) => return Err(error),
                }
            }
            (None, Some(_)) => (None, Some("not_seeded")),
            (None, None) if changed.is_empty() => (old.addresses.clone(), None),
            (None, None) => (None, Some("not_seeded")),
        };
        let mut next = Revision {
            number: old.number.checked_add(1).ok_or("revision_exhausted")?,
            source: source.to_vec(),
            fence: self.fence.load(Ordering::Acquire) + u64::from(!ready),
            ready,
            live,
            facets,
            unavailable,
            presence,
            addresses,
            ip_unavailable,
            _charge: self.budget.reserve(metadata)?,
        };
        drop(scratch);
        check_time(end)?;
        let mut pending_guard = self.pending.try_lock().map_err(|_| "busy")?;
        let intrinsic =
            next.charges().map(|charge| charge.bytes).sum::<usize>() + self._charge.bytes;
        let queued = pending_guard.bitmap_bytes();
        if next.addresses.is_some() && intrinsic + queued > MAX_BYTES {
            if intrinsic > MAX_BYTES {
                next.addresses = None;
                next.ip_unavailable = Some("native_cap");
            } else {
                pending_guard.collapse_to_rescan(&self.budget)?;
                return Err("pending");
            }
        }
        let pending = pending_guard.status();
        let next = Arc::new(next);
        let mut published = self.revision.try_lock().map_err(|_| "busy")?;
        if self.closed.load(Ordering::Acquire) {
            return Err("closed");
        }
        // The revision lock prevents a new reader retaining the old revision.
        // Both versions have passed transient admission; only allocations proven
        // to retire at this swap can offset the incoming steady ownership.
        self.budget.admit(
            next.charges(),
            old.retiring_charges(Arc::strong_count(&old) == 2),
        )?;
        *published = next;
        drop(published);
        drop(pending_guard);
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
            ready: revision.ready && !self.closed.load(Ordering::Acquire),
            cardinality: revision.live.set.len(),
            native_bytes: self.budget.used.load(Ordering::Acquire),
            peak_bytes: self.budget.peak.load(Ordering::Relaxed),
            pins,
            unavailable: revision.unavailable.iter().cloned().collect(),
            pending,
            ip_available: revision.addresses.is_some(),
            ip_unavailable_reason: revision.ip_unavailable,
        })
    }
    pub fn close(&self) -> Result<(), Error> {
        // Fence access even if an in-flight dirty NIF prevents immediate cleanup.
        // The owner must retain this resource and retry reclamation before reuse.
        self.closed.store(true, Ordering::Release);
        self.active.store(false, Ordering::Release);
        self.fence.fetch_add(1, Ordering::AcqRel);
        let _writer = self.publisher.try_lock().map_err(|_| "publisher_busy")?;
        {
            let mut registered = self.stage.try_lock().map_err(|_| "busy")?;
            if let Some(stage) = registered.as_ref().and_then(|weak| weak.upgrade()) {
                *stage.try_lock().map_err(|_| "publisher_busy")? = None;
            }
            *registered = None;
        }
        if self.budget.readers.load(Ordering::Acquire) != 0 {
            return Err("reader_busy");
        }
        let mut pending = self.pending.try_lock().map_err(|_| "busy")?;
        pending.clear(&self.budget)?;
        let mut pins = self.pins.try_lock().map_err(|_| "busy")?;
        for weak in pins.iter() {
            if let Some(slot) = weak.upgrade() {
                let mut pin = slot.try_lock().map_err(|_| "reader_busy")?;
                *pin = None;
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
            presence: BTreeMap::new(),
            addresses: None,
            ip_unavailable: None,
            _charge: self.budget.reserve(1024)?,
        };
        let mut published = self.revision.try_lock().map_err(|_| "busy")?;
        self.budget.admit(
            empty.charges(),
            published.retiring_charges(Arc::strong_count(&published) == 1),
        )?;
        *published = Arc::new(empty);
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
        if self.closed.load(Ordering::Acquire) {
            return Err("not_ready");
        }
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
        let input_bytes = program
            .iter()
            .map(|(_, key, value, _)| key.len() + value.len() + 64)
            .sum::<usize>();
        if program.len() > 65 || input_bytes > addresses::SELECTOR_BYTES + 16384 {
            return Err("expression_budget");
        }
        let _input = self.budget.reserve(2 * input_bytes + 4096)?;
        validate_program(program)?;
        let mut stack: Vec<Arc<Bitmap>> = Vec::new();
        for (opcode, facet, value, arity) in program {
            check_time(end)?;
            if matches!(*opcode, 0 | 4..=7) {
                stack.push(facets::select(self, &revision, *opcode, facet, value, end)?);
            } else if matches!(*opcode, 8 | 9) {
                let addresses = revision.addresses.as_ref().ok_or("ip_unavailable")?;
                let ranges = addresses::ranges(*opcode, value, *arity)?;
                stack.push(addresses.select(&ranges, &self.budget, end)?);
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
        let pin_charge = self.budget.reserve(512)?;
        check_time(end)?;
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
            _charge: pin_charge,
        };
        let slot = Arc::new(Mutex::new(Some(pin)));
        let mut pins = self.pins.try_lock().map_err(|_| "busy")?;
        if self.closed.load(Ordering::Acquire) {
            return Err("not_ready");
        }
        if pins.len() >= MAX_PINS {
            return Err("pin_budget");
        }
        // No other thread can see the new slot yet. Charge only the accepted
        // result and pin; the expression stack is temporary and drops below.
        {
            let pin = slot.lock().map_err(|_| "poisoned")?;
            let pin = pin.as_ref().ok_or("restart_required")?;
            self.budget.admit(
                [&pin.result.charge, &pin._charge].into_iter(),
                std::iter::empty(),
            )?;
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
    let mut selectors = 0;
    let mut ranges = 0;
    for (op, facet, value, arity) in program {
        if matches!(*op, 8 | 9) {
            predicates += 1;
            selectors += value.len();
            if !facet.is_empty() {
                return Err("invalid_expression");
            }
            ranges += addresses::ranges(*op, value, *arity)?.len();
            depths.push(1usize);
        } else if matches!(*op, 0 | 4..=7) {
            bytes += facet.len() + value.len() + 8;
            predicates += 1;
            if *arity != 0
                || facet.is_empty()
                || facet.len() > 64
                || value.len() > 256
                || (*op == 5) != value.is_empty()
                || std::str::from_utf8(value).is_err()
                || (*op >= 5 && !valid_facet(&format!("tag:{facet}")))
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
    if depths.len() != 1
        || predicates > 32
        || bytes > 16384
        || selectors > addresses::SELECTOR_BYTES
        || ranges > addresses::MAX_RANGES
    {
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
            let _scratch = self.budget.reserve(decode_reservation(bytes.len()))?;
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
            let _columns = self.budget.reserve(4096)?;
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
                        let _decode = self.budget.reserve(decode_reservation(bytes.len()))?;
                        let decoded = deserialize_bitmap(bytes)?;
                        // Intersection may expand a run container; charge from both
                        // decoded operands rather than compressed input length.
                        let _intersection = self.budget.reserve(
                            2 * (bitmap_bytes(&decoded) + pin.result.charge.bytes) + 4096,
                        )?;
                        let members = decoded & &pin.result.set;
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

fn decode_reservation(input_bytes: usize) -> usize {
    // roaring 0.11.4 keeps runs compressed. Checked decoding retains at most
    // 65,536 container descriptors plus payload, with temporary descriptions,
    // offsets and run validation. Sixteen times input bounds that storage;
    // 1 MiB also covers allocations before a truncated payload fails (notably
    // the u16 run count can allocate 262,140 bytes before read_exact). The full
    // 8 MiB accepted input still fits the independent 64 MiB decoder ceiling.
    input_bytes
        .saturating_mul(16)
        .saturating_add(1024 * 1024)
        .min(64 * 1024 * 1024)
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

    #[test]
    fn bitset_footprint_and_completed_reservations_track_owned_storage() {
        // Alternating entries force a dense bitset without run optimization.
        let make = || (0u32..65_536).step_by(2).collect::<RoaringBitmap>();
        let set = make();
        assert_eq!(set.statistics().n_bitset_containers, 1);
        let bytes = 128 + 128 + std::mem::size_of::<[u64; 1024]>();
        assert_eq!(bitmap_bytes(&set), bytes);
        let budget = Arc::new(Budget::default());
        let scratch = budget.reserve(bytes * 2 + 4096).unwrap();
        let bitmap = Bitmap::from_reserved(set, scratch).unwrap();
        assert_eq!(budget.used.load(Ordering::Acquire), bytes);
        budget
            .admit(std::iter::once(&bitmap.charge), std::iter::empty())
            .unwrap();
        assert_eq!(budget.retained.load(Ordering::Acquire), bytes);
        // A failed transfer drops its reservation and cannot reclaim the live
        // bitmap still owned by a retained revision.
        assert!(matches!(
            Bitmap::from_reserved(make(), budget.reserve(bytes - 1).unwrap()),
            Err("reservation_too_small")
        ));
        assert_eq!(budget.used.load(Ordering::Acquire), bytes);
        assert_eq!(budget.retained.load(Ordering::Acquire), bytes);
        drop(bitmap);
        assert_eq!(budget.used.load(Ordering::Acquire), 0);
        assert_eq!(budget.retained.load(Ordering::Acquire), 0);
    }
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
        (0, facet.into(), value.as_bytes().to_vec(), 0)
    }
    fn operator(code: u8, arity: u16) -> Instruction {
        (code, String::new(), Vec::new(), arity)
    }
    fn all(index: &Index) -> Query {
        index.query(b"allow", &[operator(1, 0)], 1000).unwrap().0
    }

    #[test]
    fn literal_prefixes_preserve_presence_pairing_and_published_revisions() {
        let index = Index::new(
            [1; 16],
            [2; 16],
            Kind::Device,
            ["vendor", "tag:role.edge", "tag:role.core", "tag:site"]
                .map(String::from)
                .to_vec(),
        )
        .unwrap();
        let make = |id, attrs: &[(&str, &str)]| {
            (
                id,
                true,
                attrs
                    .iter()
                    .map(|(k, v)| (k.to_string(), (*v).into()))
                    .collect(),
            )
        };
        index
            .publish(
                0,
                b"prefix-seed",
                vec![
                    make(1, &[("vendor", "unknown"), ("tag:role.edge", "blue")]),
                    make(2, &[("tag:role.core", "red"), ("tag:site", "blue")]),
                    make(
                        3,
                        &[("vendor", "Universal"), ("tag:role.edge", "blue-green")],
                    ),
                    make(
                        u32::MAX,
                        &[("vendor", "Ünicode"), ("tag:role.edge", "unknown")],
                    ),
                    make(5, &[]),
                ],
                true,
            )
            .unwrap();
        let request = |opcode, key: &str, value: &str| {
            (opcode, key.to_string(), value.as_bytes().to_vec(), 0)
        };
        let cases = [
            (request(0, "vendor", "unknown"), vec![1, 2, 5]),
            (request(4, "vendor", "un"), vec![1]),
            (request(4, "vendor", "U"), vec![3]),
            (request(4, "vendor", "Ü"), vec![u32::MAX]),
            (request(5, "role.", ""), vec![1, 2, 3, u32::MAX]),
            (request(6, "role.", "blue"), vec![1]),
            (request(7, "role.", "blue"), vec![1, 3]),
            (request(6, "role.", "unknown"), vec![u32::MAX]),
            (request(5, "Role.", ""), vec![]),
        ];
        for (instruction, expected) in cases {
            let (query, _, _, count) = index.query(b"allow", &[instruction], 1000).unwrap();
            assert_eq!(count, expected.len() as u64);
            assert_eq!(query.page(b"allow", 0, 128, 1000).unwrap(), expected);
        }
        let pinned = index
            .query(b"allow", &[request(7, "role.", "blue")], 1000)
            .unwrap()
            .0;
        index
            .publish(1, b"prefix-replace", vec![make(1, &[]), make(6, &[])], true)
            .unwrap();
        assert_eq!(pinned.page(b"allow", 0, 128, 1000).unwrap(), vec![1, 3]);
        let current = index
            .query(b"allow", &[request(7, "role.", "blue")], 1000)
            .unwrap()
            .0;
        assert_eq!(current.page(b"allow", 0, 128, 1000).unwrap(), vec![3]);
        index
            .publish(2, b"prefix-delete", vec![(3, false, vec![])], true)
            .unwrap();
        let missing_prefix = index
            .query(b"allow", &[request(4, "vendor", "un")], 1000)
            .unwrap()
            .0;
        assert!(missing_prefix
            .page(b"allow", 0, 128, 1000)
            .unwrap()
            .is_empty());
        let punctuation = index
            .query(b"allow", &[request(5, "role/", "")], 1000)
            .unwrap()
            .0;
        assert!(punctuation.page(b"allow", 0, 128, 1000).unwrap().is_empty());
        for malformed in [
            request(4, "vendor", ""),
            request(5, "", ""),
            (4, "vendor".into(), vec![255], 0),
        ] {
            assert!(matches!(
                index.query(b"allow", &[malformed], 1000),
                Err("invalid_expression")
            ));
        }
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
        assert!(Index::new(
            [1; 16],
            [2; 16],
            Kind::Device,
            vec!["vendor".into(), "tag:zone,group".into(), "tag:角色".into()],
        )
        .is_ok());
        assert!(matches!(
            Index::new([1; 16], [2; 16], Kind::Device, vec!["tag:".into()]),
            Err("unsupported_facet")
        ));
        assert!(matches!(
            Index::new(
                [1; 16],
                [2; 16],
                Kind::Device,
                vec![format!("tag:{}", "x".repeat(61))],
            ),
            Err("unsupported_facet")
        ));
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
    fn facet_caps_follow_nonempty_postings_and_stay_latched() {
        let vendor_only =
            || Index::new([1; 16], [2; 16], Kind::Device, vec!["vendor".into()]).unwrap();
        let row =
            |id: u32, vendor: &str| -> Row { (id, true, vec![("vendor".into(), vendor.into())]) };
        let publish_all = |index: &Index, rows: Vec<Row>| {
            let mut revision = 0;
            for chunk in rows.chunks(BATCH_LIMIT) {
                revision = index
                    .publish(revision, b"cap", chunk.to_vec(), true)
                    .unwrap()
                    .revision;
            }
            revision
        };
        let page = |index: &Index, value: &str| {
            let (query, _, _, count) = index
                .query(b"allow", &[predicate("vendor", value)], 1000)
                .unwrap();
            (count, query.page(b"allow", 0, 8, 1000).unwrap())
        };

        let index = vendor_only();
        let revision = publish_all(
            &index,
            (1..=1024).map(|id| row(id, &format!("v{id}"))).collect(),
        );
        assert!(index.status().unwrap().unavailable.is_empty());
        index
            .publish(revision, b"move-1024", vec![row(1024, "moved")], true)
            .unwrap();
        assert!(index.status().unwrap().unavailable.is_empty());
        assert_eq!(page(&index, "moved"), (1, vec![1024]));
        assert_eq!(page(&index, "v1024"), (0, vec![]));
        let revision = index.status().unwrap().revision;
        index
            .publish(revision, b"over-1024", vec![row(1025, "extra")], true)
            .unwrap();
        assert_eq!(
            index.status().unwrap().unavailable,
            vec!["vendor".to_string()]
        );
        assert!(matches!(
            index.query(b"allow", &[predicate("vendor", "moved")], 1000),
            Err("facet_unavailable")
        ));
        let revision = index.status().unwrap().revision;
        index
            .publish(revision, b"drop-extra", vec![(1025, false, vec![])], true)
            .unwrap();
        assert_eq!(
            index.status().unwrap().unavailable,
            vec!["vendor".to_string()]
        );
        assert!(matches!(
            index.query(b"allow", &[predicate("vendor", "moved")], 1000),
            Err("facet_unavailable")
        ));

        let simultaneous = ["vendor", "region", "vlan", "os_name"];
        let index = Index::new(
            [1; 16],
            [2; 16],
            Kind::Device,
            simultaneous
                .iter()
                .map(|name| (*name).to_string())
                .collect(),
        )
        .unwrap();
        let distinct = |id: u32| -> Row {
            (
                id,
                true,
                vec![
                    ("vendor".into(), format!("vendor-{id}").into()),
                    ("region".into(), format!("region-{id}").into()),
                    ("vlan".into(), format!("vlan-{id}").into()),
                    ("os_name".into(), format!("os-{id}").into()),
                ],
            )
        };
        let revision = publish_all(&index, (1..=1024).map(distinct).collect());
        assert!(index.status().unwrap().unavailable.is_empty());
        index
            .publish(
                revision,
                b"vendor-past-facet-cap",
                vec![(
                    1025,
                    true,
                    vec![
                        ("vendor".into(), "vendor-1025".into()),
                        ("region".into(), "region-1".into()),
                        ("vlan".into(), "vlan-1".into()),
                        ("os_name".into(), "os-1".into()),
                    ],
                )],
                true,
            )
            .unwrap();
        assert_eq!(
            index.status().unwrap().unavailable,
            vec!["vendor".to_string()]
        );
        let (query, _, _, count) = index
            .query(b"allow", &[predicate("region", "region-1")], 1000)
            .unwrap();
        assert_eq!(count, 2);
        assert_eq!(query.page(b"allow", 0, 8, 1000).unwrap(), vec![1, 1025]);
        assert!(matches!(
            index.query(b"allow", &[predicate("vendor", "vendor-1")], 1000),
            Err("facet_unavailable")
        ));
        let revision = index.status().unwrap().revision;
        index
            .publish(
                revision,
                b"drop-vendor-over",
                vec![(1025, false, vec![])],
                true,
            )
            .unwrap();
        assert_eq!(
            index.status().unwrap().unavailable,
            vec!["vendor".to_string()]
        );
        let (query, _, _, count) = index
            .query(b"allow", &[predicate("region", "region-1")], 1000)
            .unwrap();
        assert_eq!(count, 1);
        assert_eq!(query.page(b"allow", 0, 8, 1000).unwrap(), vec![1]);

        let names = ["vendor", "region", "vlan", "device_class", "os_name"];
        let index = Index::new(
            [1; 16],
            [2; 16],
            Kind::Device,
            names.iter().map(|name| (*name).to_string()).collect(),
        )
        .unwrap();
        let filled = |id: u32, vendor: &str, class: &str, os: &str| -> Row {
            (
                id,
                true,
                vec![
                    ("vendor".into(), vendor.into()),
                    ("region".into(), format!("region-{id}").into()),
                    ("vlan".into(), format!("vlan-{id}").into()),
                    ("device_class".into(), class.into()),
                    ("os_name".into(), os.into()),
                ],
            )
        };
        let mut rows: Vec<Row> = (1..=1023)
            .map(|id| filled(id, &format!("vendor-{id}"), &format!("class-{id}"), "base"))
            .collect();
        rows.push(filled(1024, "vendor-1024", "class-1", "base"));
        let revision = publish_all(&index, rows);
        assert!(index.status().unwrap().unavailable.is_empty());
        index
            .publish(
                revision,
                b"move-4096",
                vec![filled(1024, "moved", "class-1", "base")],
                true,
            )
            .unwrap();
        assert!(index.status().unwrap().unavailable.is_empty());
        let (query, _, _, count) = index
            .query(b"allow", &[predicate("vendor", "moved")], 1000)
            .unwrap();
        assert_eq!(count, 1);
        assert_eq!(query.page(b"allow", 0, 8, 1000).unwrap(), vec![1024]);
        let revision = index.status().unwrap().revision;
        index
            .publish(
                revision,
                b"over-4096",
                vec![(
                    1025,
                    true,
                    vec![
                        ("vendor".into(), "vendor-1".into()),
                        ("region".into(), "region-1".into()),
                        ("vlan".into(), "vlan-1".into()),
                        ("device_class".into(), "class-1".into()),
                        ("os_name".into(), "extra".into()),
                    ],
                )],
                true,
            )
            .unwrap();
        let mut expected: Vec<String> = names.iter().map(|name| (*name).to_string()).collect();
        expected.sort();
        assert_eq!(index.status().unwrap().unavailable, expected);
        assert!(matches!(
            index.query(b"allow", &[predicate("vendor", "moved")], 1000),
            Err("facet_unavailable")
        ));
        let revision = index.status().unwrap().revision;
        index
            .publish(revision, b"drop-global", vec![(1025, false, vec![])], true)
            .unwrap();
        assert!(matches!(
            index.query(b"allow", &[predicate("os_name", "base")], 1000),
            Err("facet_unavailable")
        ));

        let index = vendor_only();
        index
            .publish(0, b"overlength", vec![row(1, &"x".repeat(257))], true)
            .unwrap();
        assert_eq!(
            index.status().unwrap().unavailable,
            vec!["vendor".to_string()]
        );
        index
            .publish(1, b"short-after-loss", vec![row(1, "short")], true)
            .unwrap();
        assert_eq!(
            index.status().unwrap().unavailable,
            vec!["vendor".to_string()]
        );
        assert!(matches!(
            index.query(b"allow", &[predicate("vendor", "short")], 1000),
            Err("facet_unavailable")
        ));
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
        let mut runs: RoaringBitmap = (1..=1_000_000).collect();
        runs.optimize();
        assert!(runs.statistics().n_run_containers > 0);
        let sparse: RoaringBitmap = (0..=u16::MAX as u32)
            .map(|key| (key << 16) | u16::MAX as u32)
            .collect();
        for members in [runs, sparse] {
            let mut bytes = Vec::new();
            members.serialize_into(&mut bytes).unwrap();
            assert_eq!(
                query.count_serialized(b"allow", &[1; 16], &[2; 16], Kind::Device, &bytes, 1000),
                Ok(1)
            );
            let (mask, causal, availability, counts) = query
                .row_overlay(
                    b"allow",
                    &[1; 16],
                    &[2; 16],
                    Kind::Device,
                    &[ViewRow::Aggregate(&bytes)],
                    1000,
                )
                .unwrap();
            assert_eq!(mask, [1]);
            assert_eq!(causal, [3]);
            assert_eq!(availability, [if members.contains(1) { 0 } else { 2 }]);
            assert_eq!(counts, 1u32.to_le_bytes());
            bytes.push(0);
            assert_eq!(
                query.count_serialized(b"allow", &[1; 16], &[2; 16], Kind::Device, &bytes, 1000),
                Err("invalid_bitmap")
            );
        }
        // Valid one-container run header followed by a maximum run count and
        // missing payload exercises the decoder's allocation-before-EOF path.
        let truncated_run = [0x3b, 0x30, 0, 0, 1, 0, 0, 0xff, 0xff, 0xff, 0xff];
        assert_eq!(
            query.count_serialized(
                b"allow",
                &[1; 16],
                &[2; 16],
                Kind::Device,
                &truncated_run,
                1000
            ),
            Err("invalid_bitmap")
        );
        query.close().unwrap();
        assert_eq!(query.page(b"allow", 0, 1, 1000), Err("restart_required"));
        let expired = all(&index);
        expired.slot.lock().unwrap().as_mut().unwrap().expires =
            Instant::now() - Duration::from_millis(1);
        assert_eq!(index.status().unwrap().pins, 0);
        assert_eq!(expired.page(b"allow", 0, 1, 1000), Err("restart_required"));
        let pins: Vec<_> = (0..8).map(|_| all(&index)).collect();
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
        for duplicate in ["A", "B"] {
            let rows = vec![(
                1,
                true,
                vec![
                    ("vendor".into(), "A".into()),
                    ("vendor".into(), duplicate.into()),
                ],
            )];
            assert_eq!(
                index.publish(0, b"duplicate", rows, true).unwrap_err(),
                "invalid_row"
            );
            assert_eq!(index.status().unwrap().revision, 0);
            assert_eq!(index.status().unwrap().cardinality, 0);
        }
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

    #[test]
    fn closing_fences_readers_before_a_busy_publisher_can_be_reclaimed() {
        let index = index();
        index
            .publish(0, b"seed", vec![row(1, "A", "healthy")], true)
            .unwrap();
        let query = all(&index);
        let writer = index.publisher.lock().unwrap();
        let reader = index.budget.reader().unwrap();
        assert_eq!(index.close(), Err("publisher_busy"));
        assert!(!index.status().unwrap().ready);
        assert_eq!(query.page(b"allow", 0, 128, 1000), Err("not_ready"));
        drop(writer);
        assert_eq!(index.close(), Err("reader_busy"));
        drop(reader);
        assert_eq!(
            index
                .publish(1, b"late", vec![row(2, "B", "healthy")], true)
                .unwrap_err(),
            "closed"
        );
        index.close().unwrap();
        assert_eq!(index.status().unwrap().cardinality, 0);
    }

    #[test]
    fn real_sparse_postings_hit_the_budget_without_partially_publishing() {
        let supported: Vec<_> = (0..32).map(|n| format!("tag:synthetic-{n}")).collect();
        let index = Index::new([1; 16], [2; 16], Kind::Device, supported.clone()).unwrap();
        let mut accepted = index.status().unwrap();
        let mut rejected = false;
        // One ordinal per high-16-bit container exercises real allocated metadata,
        // not a mocked allocator or a reduced test-only production limit.
        for start in (0u32..65_536).step_by(500) {
            let rows = (start..(start + 500).min(65_536))
                .map(|n| {
                    (
                        (n << 16) | 1,
                        true,
                        supported
                            .iter()
                            .map(|key| (key.clone(), "a".into()))
                            .collect(),
                    )
                })
                .collect();
            match index.publish(accepted.revision, &start.to_le_bytes(), rows, true) {
                Ok(status) => accepted = status,
                Err("native_memory_budget") => {
                    rejected = true;
                    break;
                }
                Err(error) => panic!("unexpected admission error: {error}"),
            }
        }
        assert!(
            rejected,
            "the real sparse allocation must reach the fixed cap"
        );
        let actual = index.status().unwrap();
        assert_eq!(
            (actual.revision, actual.cardinality, actual.source),
            (accepted.revision, accepted.cardinality, accepted.source)
        );
        assert!(actual.native_bytes <= MAX_BYTES);
        // A full query result also needs admission headroom. Release known rows
        // and verify the failed batch did not enter membership as capacity returns.
        let mut revision = actual.revision;
        for start in (0..1000).step_by(500) {
            let deleted = (start..start + 500)
                .map(|n| ((n << 16) | 1, false, vec![]))
                .collect();
            revision = index
                .publish(revision, b"synthetic-release", deleted, true)
                .unwrap()
                .revision;
        }
        let (query, _, _, total) = index.query(b"allow", &[operator(1, 0)], 1000).unwrap();
        assert_eq!(total, accepted.cardinality - 1000);
        assert_eq!(
            query.page(b"allow", 0, 1, 1000).unwrap(),
            vec![(1000 << 16) | 1]
        );
        assert_eq!(
            query
                .facets(b"allow", &[(supported[0].clone(), "a".into())], 1000)
                .unwrap(),
            vec![total]
        );
    }

    #[test]
    fn pending_queue_omits_ip_without_latching_native_cap() {
        let supported: Vec<_> = (0..32).map(|n| format!("tag:synthetic-{n}")).collect();
        let index = Index::new([9; 16], [8; 16], Kind::Device, supported.clone()).unwrap();
        let rows = |start: u32, count: u32, value: &str| -> Vec<Row> {
            (start..start + count)
                .map(|n| {
                    (
                        (n << 16) | 1,
                        true,
                        supported
                            .iter()
                            .map(|key| (key.clone(), value.into()))
                            .collect(),
                    )
                })
                .collect()
        };
        let ipv4 = |ordinal: u32| {
            let host = (ordinal >> 16) + 1;
            vec![10, (host >> 16) as u8, (host >> 8) as u8, host as u8]
        };
        let address_page = |ordinal: u32| {
            let (query, _, _, total) = index
                .query(b"allow", &[(8, String::new(), ipv4(ordinal), 32)], 1000)
                .unwrap();
            let page = query.page(b"allow", 0, 4, 1000).unwrap();
            query.close().unwrap();
            (total, page)
        };
        let publish = |revision, source: &[u8], rows: Vec<Row>| {
            let completed: Vec<_> = rows.iter().map(|(id, _, _)| *id).collect();
            let addresses: Vec<_> = rows
                .iter()
                .filter(|(_, live, _)| *live)
                .map(|(id, _, _)| (*id, ipv4(*id)))
                .collect();
            let stage = index.begin_publish(revision, source, rows, true).unwrap();
            assert!(stage.add(&addresses, &completed).unwrap());
            index.finish_publish(&stage).unwrap_or_else(|error| {
                panic!("publication {source:?} failed: {error}; {:?}", index.status());
            });
            // finish_publish's receipt can include the source stage's charges;
            // after it returns those allocations have been released.
            index.status().unwrap()
        };
        let mut status = index.status().unwrap();
        let mut count = 0u32;
        // Separate values per batch share old postings instead of first exhausting
        // transient COW capacity. Every retained byte is real shipping index data.
        while status.native_bytes < MAX_BYTES - 3_000_000 {
            assert!(count < 65_000, "fixture must reach the production cap");
            status = publish(
                status.revision,
                b"seed",
                rows(count, 500, &count.to_string()),
            );
            assert!(status.ip_available);
            assert!(status.unavailable.is_empty());
            count += 500;
        }
        let probe = rows(count, 100, "probe");
        let probe_ids: Vec<_> = probe.iter().map(|(id, _, _)| *id).collect();
        // The exact growth succeeds without a queue. Removing it restores the
        // fixture before the same source batch is retried with retained hints.
        status = publish(status.revision, b"control", probe.clone());
        assert!(status.ip_available);
        status = publish(
            status.revision,
            b"restore",
            probe_ids.iter().map(|id| (*id, false, vec![])).collect(),
        );
        assert!(status.ip_available);
        assert_eq!(status.cardinality, u64::from(count));
        let mut dirty = 0u32;
        while index.status().unwrap().native_bytes < MAX_BYTES - 100_000 {
            assert!(
                dirty + 500 <= count,
                "retained live hints must fill the remaining budget"
            );
            let ids: Vec<_> = (dirty..dirty + 500).map(|n| (n << 16) | 1).collect();
            index.mark_dirty(&ids, false).unwrap();
            dirty += 500;
        }
        let before = index.status().unwrap();
        assert_eq!(before.pending.pending_count, u64::from(dirty));
        assert!(!before.pending.rescan_needed);
        assert!(before.native_bytes <= MAX_BYTES);
        assert!(before.ip_available);
        let completed: Vec<_> = probe.iter().map(|(id, _, _)| *id).collect();
        let addresses: Vec<_> = probe
            .iter()
            .filter(|(_, live, _)| *live)
            .map(|(id, _, _)| (*id, ipv4(*id)))
            .collect();
        let stage = index
            .begin_publish(before.revision, b"probe", probe.clone(), true)
            .unwrap();
        assert!(stage.add(&addresses, &completed).unwrap());
        assert_eq!(index.finish_publish(&stage).unwrap_err(), "pending");
        let during = index.status().unwrap();
        assert_eq!(during.revision, before.revision);
        assert_eq!(during.cardinality, u64::from(count));
        assert!(during.ip_available);
        assert_eq!(during.ip_unavailable_reason, None);
        assert_eq!(during.pending.pending_count, 0);
        assert!(during.pending.rescan_needed);
        assert_eq!(
            during.pending.rescan_generation,
            before.pending.rescan_generation + 1
        );
        assert!(during.native_bytes <= MAX_BYTES);
        drop(stage);
        let first = 1u32;
        let last = ((count - 1) << 16) | 1;
        let probe_ordinal = (count << 16) | 1;
        assert_eq!(address_page(first), (1, vec![first]));
        assert_eq!(address_page(last), (1, vec![last]));
        assert_eq!(address_page(probe_ordinal), (0, vec![]));
        let (facet, _, _, probe_total) = index
            .query(b"allow", &[predicate(&supported[0], "probe")], 1000)
            .unwrap();
        assert_eq!(probe_total, 0);
        facet.close().unwrap();
        let restored = publish(during.revision, b"retry", probe);
        assert!(restored.ip_available);
        assert_eq!(restored.ip_unavailable_reason, None);
        assert_eq!(restored.cardinality, u64::from(count) + 100);
        assert_eq!(address_page(first), (1, vec![first]));
        assert_eq!(address_page(last), (1, vec![last]));
        assert_eq!(address_page(probe_ordinal), (1, vec![probe_ordinal]));
        let (facet, _, _, probe_total) = index
            .query(b"allow", &[predicate(&supported[0], "probe")], 1000)
            .unwrap();
        assert_eq!(probe_total, 100);
        assert_eq!(facet.page(b"allow", 0, 128, 1000).unwrap(), probe_ids);
        facet.close().unwrap();
    }
}
