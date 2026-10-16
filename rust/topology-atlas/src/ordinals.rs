//! Canonical membership is paired with geometry, never encoded by a row offset.
//! Inventory owns ordinal allocation and uniqueness; this mapping retains no UID map.

use std::collections::BTreeMap;
use std::mem::size_of;
use std::time::{Duration, Instant};

use roaring::RoaringBitmap;

use crate::{AggregateSelection, Error, World};

pub const ORDINAL_MAPPING_BYTES: usize = 32 * 1024 * 1024;
pub const ORDINAL_PORTABLE_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub struct OrdinalInfo {
    pub world_revision: String,
    pub dictionary_epoch: [u8; 16],
    pub ready: bool,
    pub mapped: usize,
    pub total: usize,
    pub retained_bytes: usize,
}

pub struct CanonicalOrdinals {
    world_revision: String,
    dictionary_epoch: [u8; 16],
    ordinals: Vec<u32>,
    mapped: usize,
    ready: bool,
}

impl CanonicalOrdinals {
    pub fn new(world: &World, dictionary_epoch: [u8; 16]) -> Result<Self, Error> {
        let bytes = world
            .device_count()
            .checked_mul(size_of::<u32>())
            .and_then(|n| n.checked_add(size_of::<Self>() + world.detail_revision().len()))
            .ok_or(Error::OrdinalBudgetExceeded)?;
        if bytes > ORDINAL_MAPPING_BYTES {
            return Err(Error::OrdinalBudgetExceeded);
        }
        let mut ordinals = Vec::new();
        ordinals
            .try_reserve_exact(world.device_count())
            .map_err(|_| Error::OrdinalBudgetExceeded)?;
        ordinals.resize(world.device_count(), 0);
        Ok(Self {
            world_revision: world.detail_revision().into(),
            dictionary_epoch,
            ordinals,
            mapped: 0,
            ready: false,
        })
    }

    fn check_world(&self, world: &World) -> Result<(), Error> {
        if self.world_revision != world.detail_revision() {
            Err(Error::StaleDetailRevision)
        } else {
            Ok(())
        }
    }

    pub fn info(&self, world: &World) -> Result<OrdinalInfo, Error> {
        self.check_world(world)?;
        Ok(OrdinalInfo {
            world_revision: self.world_revision.clone(),
            dictionary_epoch: self.dictionary_epoch,
            ready: self.ready,
            mapped: self.mapped,
            total: self.ordinals.len(),
            retained_bytes: size_of::<Self>()
                + self.world_revision.capacity()
                + self.ordinals.capacity() * size_of::<u32>(),
        })
    }

    /// Unknown world UIDs are ignored so one keyset dictionary scan can seed any world.
    /// Validate the entire page before changing anything; replaying it is harmless.
    pub fn apply(&mut self, world: &World, rows: &[(String, u32)]) -> Result<OrdinalInfo, Error> {
        self.check_world(world)?;
        if self.ready {
            return Err(Error::OrdinalMappingSealed);
        }
        if rows.len() > 500 {
            return Err(Error::OrdinalBudgetExceeded);
        }
        let mut updates = BTreeMap::new();
        for (uid, ordinal) in rows {
            if uid.is_empty() || uid.len() > 256 || *ordinal == 0 {
                return Err(Error::InvalidOrdinal);
            }
            let Some(&index) = world.identities.get(uid) else {
                continue;
            };
            let before = self.ordinals[index as usize];
            if (before != 0 && before != *ordinal)
                || updates
                    .insert(index, *ordinal)
                    .is_some_and(|old| old != *ordinal)
            {
                return Err(Error::InvalidOrdinal);
            }
        }
        for (index, ordinal) in updates {
            let slot = &mut self.ordinals[index as usize];
            self.mapped += usize::from(*slot == 0);
            *slot = ordinal;
        }
        self.info(world)
    }

    /// Unmapped geometry can be provisional or noncanonical, so zero does not block sealing.
    pub fn seal(&mut self, world: &World) -> Result<OrdinalInfo, Error> {
        self.check_world(world)?;
        self.ready = true;
        self.info(world)
    }

    fn check_ready(&self, world: &World) -> Result<(), Error> {
        self.check_world(world)?;
        if self.ready {
            Ok(())
        } else {
            Err(Error::OrdinalMappingNotReady)
        }
    }

    pub fn device_ordinals(&self, world: &World, ids: &[String]) -> Result<Vec<u32>, Error> {
        self.check_ready(world)?;
        if ids.len() > 8192 {
            return Err(Error::OrdinalBudgetExceeded);
        }
        ids.iter()
            .map(|uid| {
                if uid.is_empty() || uid.len() > 256 {
                    return Err(Error::InvalidOrdinal);
                }
                Ok(world
                    .identities
                    .get(uid)
                    .map_or(0, |i| self.ordinals[*i as usize]))
            })
            .collect()
    }

    /// O(member count) traversal stays native; no full aggregate list crosses the BEAM.
    /// The caller supplies its remaining view-byte budget before serialization and
    /// the pinned query's epoch when intersecting these portable bytes.
    pub fn aggregate(
        &self,
        world: &World,
        aggregate: &AggregateSelection,
        max_bytes: usize,
        timeout_ms: u64,
    ) -> Result<Vec<u8>, Error> {
        self.check_ready(world)?;
        if !(1..=1000).contains(&timeout_ms) || !(1..=ORDINAL_PORTABLE_BYTES).contains(&max_bytes) {
            return Err(Error::InvalidBudget);
        }
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        let mut bitmap = RoaringBitmap::new();
        for (visited, index) in aggregate.member_indices(world)?.enumerate() {
            if visited % 1024 == 0 {
                check_time(deadline)?;
            }
            // Bound output/container growth while avoiding a container scan for every row.
            if visited % 65_536 == 0 {
                check_bitmap(&bitmap, max_bytes)?;
            }
            let ordinal = self.ordinals[index];
            if ordinal != 0 {
                bitmap.insert(ordinal);
            }
        }
        check_bitmap(&bitmap, max_bytes)?;
        check_time(deadline)?;
        let mut bytes = Vec::with_capacity(bitmap.serialized_size());
        bitmap
            .serialize_into(&mut bytes)
            .map_err(|_| Error::OrdinalBudgetExceeded)?;
        check_time(deadline)?;
        Ok(bytes)
    }
}

fn check_time(deadline: Instant) -> Result<(), Error> {
    if Instant::now() >= deadline {
        Err(Error::DeadlineExceeded)
    } else {
        Ok(())
    }
}

fn check_bitmap(bitmap: &RoaringBitmap, max_bytes: usize) -> Result<(), Error> {
    let stats = bitmap.statistics();
    // roaring 0.11.4 reports bit capacity in n_bytes_bitset_containers;
    // each allocated Box<[u64; 1024]> occupies 8192 bytes. Keep the array
    // statistic's conservative allowance and the outer-container metadata.
    let allocated = 128 * stats.n_containers as usize
        + stats.n_bytes_array_containers as usize
        + 8192 * stats.n_bitset_containers as usize
        + stats.n_bytes_run_containers as usize;
    if bitmap.serialized_size() > max_bytes
        || allocated + bitmap.serialized_size() > 32 * 1024 * 1024
    {
        Err(Error::OrdinalBudgetExceeded)
    } else {
        Ok(())
    }
}
