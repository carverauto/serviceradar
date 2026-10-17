//! One bounded unpublished source transaction per index. Partial address pages
//! never become visible, and dropping a cancelled worker releases its staging.
use super::addresses::{Entry, STAGE_BYTES};
use super::{Budget, Charge, Error, Index, Row, Status, Value, BATCH_LIMIT};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub(super) struct Staged {
    pub expected: u64,
    pub source: Vec<u8>,
    pub rows: Vec<Row>,
    pub ready: bool,
    live: BTreeMap<u32, bool>,
    complete: BTreeSet<u32>,
    pub v4: Vec<Entry<4>>,
    pub v6: Vec<Entry<16>>,
    pub unavailable: Option<&'static str>,
    expires: Instant,
    charges: Vec<Charge>,
    bytes: usize,
}
pub(super) type StageSlot = Mutex<Option<Staged>>;
pub struct Stage {
    pub(super) slot: Arc<StageSlot>,
    budget: Arc<Budget>,
    closed: Arc<AtomicBool>,
}
impl Stage {
    pub fn add(&self, values: &[(u32, Vec<u8>)], completed: &[u32]) -> Result<bool, Error> {
        if values.len() > BATCH_LIMIT || completed.len() > BATCH_LIMIT {
            return Err("batch_budget");
        }
        let mut slot = self.slot.try_lock().map_err(|_| "busy")?;
        let stage = self.current(&mut slot)?;
        for (id, bytes) in values {
            if stage.live.get(id) != Some(&true)
                || stage.complete.contains(id)
                || !matches!(bytes.len(), 4 | 16)
            {
                return Err("invalid_address_row");
            }
        }
        if completed.iter().any(|id| !stage.live.contains_key(id)) {
            return Err("invalid_address_row");
        }
        if stage.unavailable.is_none() {
            let charge_bytes = 256
                + values
                    .iter()
                    .map(|(_, bytes)| bytes.len() + 4)
                    .sum::<usize>();
            if stage.bytes + charge_bytes > STAGE_BYTES {
                stage.disable("native_cap");
            } else {
                let charge = self.budget.reserve(charge_bytes)?;
                let n4 = values.iter().filter(|(_, bytes)| bytes.len() == 4).count();
                stage.v4.reserve_exact(n4);
                stage.v6.reserve_exact(values.len() - n4);
                for (ordinal, address) in values {
                    if address.len() == 4 {
                        stage.v4.push(Entry {
                            ordinal: *ordinal,
                            address: address.as_slice().try_into().unwrap(),
                        });
                    } else {
                        stage.v6.push(Entry {
                            ordinal: *ordinal,
                            address: address.as_slice().try_into().unwrap(),
                        });
                    }
                }
                stage.bytes += charge_bytes;
                stage.charges.push(charge);
            }
        }
        stage.complete.extend(completed);
        Ok(stage.unavailable.is_none())
    }
    pub fn unavailable(&self) -> Result<(), Error> {
        let mut slot = self.slot.try_lock().map_err(|_| "busy")?;
        self.current(&mut slot)?.disable("source_cap");
        Ok(())
    }
    pub fn abort(&self) -> Result<(), Error> {
        *self.slot.try_lock().map_err(|_| "busy")? = None;
        Ok(())
    }
    fn current<'a>(&self, slot: &'a mut Option<Staged>) -> Result<&'a mut Staged, Error> {
        if self.closed.load(Ordering::Acquire) {
            *slot = None;
            return Err("closed");
        }
        if slot
            .as_ref()
            .is_some_and(|stage| stage.expires <= Instant::now())
        {
            *slot = None;
            return Err("stage_expired");
        }
        slot.as_mut().ok_or("stage_closed")
    }
}
impl Staged {
    fn disable(&mut self, reason: &'static str) {
        self.unavailable = Some(reason);
        self.v4 = Vec::new();
        self.v6 = Vec::new();
        self.charges.truncate(1);
        self.bytes = self.charges[0].bytes;
    }
}
impl Index {
    pub fn begin_publish(
        &self,
        expected: u64,
        source: &[u8],
        rows: Vec<Row>,
        ready: bool,
    ) -> Result<Stage, Error> {
        let _writer = self.publisher.try_lock().map_err(|_| "publisher_busy")?;
        if self.closed.load(Ordering::Acquire) {
            return Err("closed");
        }
        if rows.len() > BATCH_LIMIT || source.is_empty() || source.len() > 128 {
            return Err("batch_budget");
        }
        let unavailable = {
            let old = self.revision.try_lock().map_err(|_| "busy")?;
            if old.number != expected {
                return Err("revision_conflict");
            }
            old.ip_unavailable
        };
        let mut registered = self.stage.try_lock().map_err(|_| "busy")?;
        if let Some(active) = registered.as_ref().and_then(|weak| weak.upgrade()) {
            let mut active = active.try_lock().map_err(|_| "publisher_busy")?;
            if active
                .as_ref()
                .is_some_and(|stage| stage.expires <= Instant::now())
            {
                *active = None;
            }
            if active.is_some() {
                return Err("publisher_busy");
            }
        }
        let mut live = BTreeMap::new();
        let mut bytes = 65536 + rows.capacity() * std::mem::size_of::<Row>();
        for (id, current, attrs) in &rows {
            if *id == 0 || live.insert(*id, *current).is_some() || attrs.len() > 32 {
                return Err("invalid_row");
            }
            bytes += attrs.capacity() * std::mem::size_of::<(String, Value)>();
            for (key, value) in attrs {
                if !self.supported.contains(key) {
                    return Err("invalid_facet_value");
                }
                bytes += key.capacity();
                if let Value::Exact(value) = value {
                    bytes += value.capacity();
                }
            }
        }
        if bytes > STAGE_BYTES {
            return Err("batch_budget");
        }
        let charge = self.budget.reserve(bytes)?;
        let complete = live
            .iter()
            .filter_map(|(id, is_live)| (!is_live).then_some(*id))
            .collect();
        let slot = Arc::new(Mutex::new(Some(Staged {
            expected,
            source: source.to_vec(),
            rows,
            ready,
            live,
            complete,
            v4: Vec::new(),
            v6: Vec::new(),
            unavailable,
            expires: Instant::now() + Duration::from_secs(10),
            charges: vec![charge],
            bytes,
        })));
        *registered = Some(Arc::downgrade(&slot));
        Ok(Stage {
            slot,
            budget: self.budget.clone(),
            closed: self.closed.clone(),
        })
    }
    pub fn finish_publish(&self, stage: &Stage) -> Result<Status, Error> {
        if !Arc::ptr_eq(&self.budget, &stage.budget) {
            return Err("identity_mismatch");
        }
        let mut slot = stage.slot.try_lock().map_err(|_| "busy")?;
        let current = stage.current(&mut slot)?;
        if current.unavailable.is_none() && current.complete.len() != current.live.len() {
            return Err("incomplete_addresses");
        }
        let mut data = slot.take().ok_or("stage_closed")?;
        // The source transaction is complete. Consume its charges only after the
        // publication attempt; any failure retains the old accepted revision.
        self.publish_complete(
            data.expected,
            &data.source,
            std::mem::take(&mut data.rows),
            data.ready,
            Some((
                std::mem::take(&mut data.v4),
                std::mem::take(&mut data.v6),
                data.unavailable,
            )),
        )
    }
}
