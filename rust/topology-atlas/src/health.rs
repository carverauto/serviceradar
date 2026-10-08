//! Last observed inventory availability, independent of geometry and causality.
//! The serving owner supplies current authorization, generation fences, freshness,
//! and bounded read-dispatch sequences; these are not database change sequences.

use std::collections::HashSet;
use std::mem::size_of;

use crate::{Error, TileSelection, World};

pub const HEALTH_BATCH_LIMIT: usize = 500;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum HealthState {
    #[default]
    Unknown,
    Healthy,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HealthObservation {
    pub device_id: String,
    pub state: HealthState,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceIdsCursor {
    pub world_revision: String,
    pub offset: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceIdsPage {
    pub ids: Vec<String>,
    pub next: Option<DeviceIdsCursor>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HealthCounts {
    pub healthy: u64,
    pub unavailable: u64,
    pub unknown: u64,
    /// Completed inventory lookups, including explicitly unknown observations.
    pub observed: u64,
    pub total: u64,
}

impl HealthCounts {
    fn from_counters(total: usize, [healthy, unavailable, observed]: [u32; 3]) -> Self {
        Self {
            healthy: u64::from(healthy),
            unavailable: u64::from(unavailable),
            unknown: total as u64 - u64::from(healthy) - u64::from(unavailable),
            observed: u64::from(observed),
            total: total as u64,
        }
    }

    fn subtract(&mut self, other: Self) {
        self.healthy -= other.healthy;
        self.unavailable -= other.unavailable;
        self.unknown -= other.unknown;
        self.observed -= other.observed;
        self.total -= other.total;
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GlyphHealth {
    pub id: String,
    pub counts: HealthCounts,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TileHealth {
    pub world_revision: String,
    pub tile_revision: String,
    /// Nonzero epoch supplied by the owner when it creates a resource.
    pub epoch: u64,
    /// Advances only when availability or lookup coverage changes.
    pub revision: u64,
    pub observation_sequence: u64,
    pub glyphs: Vec<GlyphHealth>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HealthApply {
    pub applied: usize,
    pub unchanged: usize,
    pub stale: usize,
    pub unknown_ids: usize,
    pub revision: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HealthInfo {
    pub epoch: u64,
    pub revision: u64,
    pub observation_sequence: u64,
    pub observed: u64,
    pub total: u64,
    pub retained_bytes: usize,
}

/// Copy while holding the old resource lock, then release it before remapping.
/// No UID map or World reference is retained by this temporary snapshot.
pub struct HealthSnapshot {
    world_revision: String,
    states: Vec<HealthState>,
    sequences: Vec<u64>,
    observation_sequence: u64,
}

impl HealthSnapshot {
    pub fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            + self.world_revision.capacity()
            + self.states.capacity() * size_of::<HealthState>()
            + self.sequences.capacity() * size_of::<u64>()
    }
}

/// One mutable availability index. Synchronization belongs to its resource owner.
/// UID lookup and Morton ordering remain owned exclusively by the supplied World.
pub struct HealthIndex {
    world_revision: String,
    states: Vec<HealthState>,
    sequences: Vec<u64>,
    counts: Vec<[u32; 3]>,
    epoch: u64,
    revision: u64,
    observation_sequence: u64,
}

impl HealthIndex {
    pub fn info(&self, world: &World) -> Result<HealthInfo, Error> {
        self.check_world(world)?;
        Ok(HealthInfo {
            epoch: self.epoch,
            revision: self.revision,
            observation_sequence: self.observation_sequence,
            observed: u64::from(self.prefix(self.states.len())[2]),
            total: self.states.len() as u64,
            retained_bytes: self.retained_bytes(),
        })
    }

    pub fn new(world: &World, epoch: u64) -> Result<Self, Error> {
        if epoch == 0 {
            return Err(Error::InvalidHealthUpdate);
        }
        Ok(Self {
            world_revision: world.detail_revision().into(),
            states: vec![HealthState::Unknown; world.device_count()],
            sequences: vec![0; world.device_count()],
            counts: vec![[0; 3]; world.device_count() + 1],
            epoch,
            revision: 0,
            observation_sequence: 0,
        })
    }

    pub fn snapshot(&self) -> HealthSnapshot {
        HealthSnapshot {
            world_revision: self.world_revision.clone(),
            states: self.states.clone(),
            sequences: self.sequences.clone(),
            observation_sequence: self.observation_sequence,
        }
    }

    pub fn rebase(
        old_world: &World,
        snapshot: &HealthSnapshot,
        new_world: &World,
        epoch: u64,
    ) -> Result<Self, Error> {
        if snapshot.world_revision != old_world.detail_revision() {
            return Err(Error::StaleDetailRevision);
        }
        let mut result = Self::new(new_world, epoch)?;
        for (i, node) in new_world.positions.iter().enumerate() {
            if let Some(&old_index) = old_world.identities.get(&node.id) {
                let old_index = old_index as usize;
                result.states[i] = snapshot.states[old_index];
                result.sequences[i] = snapshot.sequences[old_index];
                result.counts[i + 1] = counters(result.states[i], result.sequences[i]);
            }
        }
        // Build Fenwick partial sums in O(N), after releasing the old resource lock.
        for i in 1..result.counts.len() {
            let parent = i + i.isolate_lowest_one();
            if parent < result.counts.len() {
                for column in 0..3 {
                    result.counts[parent][column] += result.counts[i][column];
                }
            }
        }
        result.observation_sequence = snapshot.observation_sequence;
        Ok(result)
    }

    pub fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            + self.world_revision.capacity()
            + self.states.capacity() * size_of::<HealthState>()
            + self.sequences.capacity() * size_of::<u64>()
            + self.counts.capacity() * size_of::<[u32; 3]>()
    }

    pub fn apply(
        &mut self,
        world: &World,
        sequence: u64,
        rows: &[HealthObservation],
    ) -> Result<HealthApply, Error> {
        self.check_world(world)?;
        if sequence == 0 || rows.len() > HEALTH_BATCH_LIMIT {
            return Err(Error::InvalidHealthUpdate);
        }
        let mut ids = HashSet::with_capacity(rows.len());
        if rows
            .iter()
            .any(|r| r.device_id.is_empty() || !ids.insert(r.device_id.as_str()))
        {
            return Err(Error::InvalidHealthUpdate);
        }
        let mut result = HealthApply::default();
        let mut updates = Vec::with_capacity(rows.len());
        for row in rows {
            let Some(&index) = world.identities.get(&row.device_id) else {
                result.unknown_ids += 1;
                continue;
            };
            let index = index as usize;
            if sequence <= self.sequences[index] {
                result.stale += 1;
            } else {
                if self.states[index] == row.state && self.sequences[index] != 0 {
                    result.unchanged += 1;
                } else {
                    result.applied += 1;
                }
                updates.push((index, row.state));
            }
        }
        // Validate the only fallible counter transition before touching any row.
        let revision = if result.applied > 0 {
            self.revision
                .checked_add(1)
                .ok_or(Error::InvalidHealthUpdate)?
        } else {
            self.revision
        };
        for (index, state) in updates {
            let old = counters(self.states[index], self.sequences[index]);
            let new = counters(state, sequence);
            self.states[index] = state;
            self.sequences[index] = sequence;
            let mut position = index + 1;
            while position < self.counts.len() {
                for column in 0..3 {
                    self.counts[position][column] =
                        self.counts[position][column] - old[column] + new[column];
                }
                position += position.isolate_lowest_one();
            }
        }
        self.revision = revision;
        self.observation_sequence = self.observation_sequence.max(sequence);
        result.revision = revision;
        Ok(result)
    }

    pub fn tile_health(
        &self,
        world: &World,
        selection: &TileSelection,
    ) -> Result<TileHealth, Error> {
        self.check_world(world)?;
        if selection.world_revision != self.world_revision {
            return Err(Error::StaleDetailRevision);
        }
        let mut counts = vec![HealthCounts::default(); selection.glyphs.len()];
        for &(index, glyph) in &selection.promoted {
            counts[glyph as usize] = self.point(index as usize);
        }
        for (range, glyph) in &selection.groups {
            let before = self.prefix(range.start);
            let after = self.prefix(range.end);
            let mut group = HealthCounts::from_counters(
                range.len(),
                std::array::from_fn(|i| after[i] - before[i]),
            );
            for &(index, _) in &selection.promoted {
                if range.contains(&(index as usize)) {
                    group.subtract(self.point(index as usize));
                }
            }
            counts[*glyph as usize] = group;
        }
        Ok(TileHealth {
            world_revision: self.world_revision.clone(),
            tile_revision: selection.tile_revision.clone(),
            epoch: self.epoch,
            revision: self.revision,
            observation_sequence: self.observation_sequence,
            glyphs: selection
                .glyphs
                .iter()
                .zip(counts)
                .map(|(glyph, counts)| GlyphHealth {
                    id: glyph.id.clone(),
                    counts,
                })
                .collect(),
        })
    }

    fn check_world(&self, world: &World) -> Result<(), Error> {
        if self.world_revision == world.detail_revision() {
            Ok(())
        } else {
            Err(Error::StaleDetailRevision)
        }
    }

    fn point(&self, index: usize) -> HealthCounts {
        HealthCounts::from_counters(1, counters(self.states[index], self.sequences[index]))
    }

    fn prefix(&self, mut end: usize) -> [u32; 3] {
        let mut result = [0; 3];
        while end > 0 {
            for (i, count) in result.iter_mut().enumerate() {
                *count += self.counts[end][i];
            }
            end -= end.isolate_lowest_one();
        }
        result
    }
}

impl World {
    pub fn device_ids_page(
        &self,
        cursor: Option<&DeviceIdsCursor>,
        limit: usize,
    ) -> Result<DeviceIdsPage, Error> {
        if limit == 0 || limit > HEALTH_BATCH_LIMIT {
            return Err(Error::InvalidBudget);
        }
        let offset = if let Some(cursor) = cursor {
            if cursor.world_revision != self.detail_revision() {
                return Err(Error::StaleDetailRevision);
            }
            cursor.offset as usize
        } else {
            0
        };
        if offset > self.positions.len() {
            return Err(Error::InvalidDetailCursor);
        }
        let end = (offset + limit).min(self.positions.len());
        Ok(DeviceIdsPage {
            ids: self.positions[offset..end]
                .iter()
                .map(|p| p.id.clone())
                .collect(),
            next: (end < self.positions.len()).then(|| DeviceIdsCursor {
                world_revision: self.detail_revision().into(),
                offset: end as u32,
            }),
        })
    }
}

fn counters(state: HealthState, sequence: u64) -> [u32; 3] {
    [
        u32::from(state == HealthState::Healthy),
        u32::from(state == HealthState::Unavailable),
        u32::from(sequence > 0),
    ]
}
