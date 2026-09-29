//! Mutable availability is isolated from immutable geometry resources. Locks
//! cover bounded updates/reads and the detached snapshot copy, never rebase.

use std::sync::Mutex;

use rustler::{Env, NifMap, NifUnitEnum, Resource, ResourceArc, Term};
use serviceradar_topology_atlas::{
    DeviceIdsCursor, HealthCounts, HealthIndex, HealthObservation, HealthState,
};

use crate::WorldResource;
use crate::details::{SelectionResource, engine_error, read_reply};

mod atoms {
    rustler::atoms! {unavailable, invalid_request, invalid_cursor}
}

struct HealthResource(Mutex<HealthIndex>);

#[rustler::resource_impl]
impl Resource for HealthResource {
    fn destructor(self, _env: Env<'_>) {
        crate::reclaim(self);
    }
}

#[derive(NifUnitEnum)]
enum WireState {
    Unknown,
    Healthy,
    Unavailable,
}

#[derive(NifMap)]
struct Observation {
    device_id: String,
    state: WireState,
}

impl From<Observation> for HealthObservation {
    fn from(row: Observation) -> Self {
        Self {
            device_id: row.device_id,
            state: match row.state {
                WireState::Unknown => HealthState::Unknown,
                WireState::Healthy => HealthState::Healthy,
                WireState::Unavailable => HealthState::Unavailable,
            },
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn new_health(env: Env<'_>, world: ResourceArc<WorldResource>, epoch: u64) -> Term<'_> {
    crate::admission::call(env, &crate::admission::HEALTH_BUILD, || {
        read_reply(env, || {
            let health = HealthIndex::new(&world.0.geometry, epoch).map_err(engine_error)?;
            Ok(ResourceArc::new(HealthResource(Mutex::new(health))))
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn rebase_health(
    env: Env<'_>,
    old_world: ResourceArc<WorldResource>,
    old_health: ResourceArc<HealthResource>,
    new_world: ResourceArc<WorldResource>,
    epoch: u64,
) -> Term<'_> {
    crate::admission::call(env, &crate::admission::HEALTH_BUILD, || {
        read_reply(env, || {
            let snapshot = {
                let health = old_health.0.lock().map_err(|_| atoms::unavailable())?;
                health.snapshot()
            };
            let rebased = HealthIndex::rebase(
                &old_world.0.geometry,
                &snapshot,
                &new_world.0.geometry,
                epoch,
            )
            .map_err(engine_error)?;
            Ok(ResourceArc::new(HealthResource(Mutex::new(rebased))))
        })
    })
}

#[derive(NifMap)]
struct WireIdsCursor {
    world_revision: String,
    offset: u32,
}

#[derive(NifMap)]
struct WireIdsPage {
    ids: Vec<String>,
    next_cursor: Option<WireIdsCursor>,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn device_ids_page<'a>(
    env: Env<'a>,
    world: ResourceArc<WorldResource>,
    cursor: Term<'a>,
    limit: usize,
) -> Term<'a> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_reply(env, || {
            let cursor = cursor
                .decode::<Option<WireIdsCursor>>()
                .map_err(|_| atoms::invalid_cursor())?
                .map(|c| DeviceIdsCursor {
                    world_revision: c.world_revision,
                    offset: c.offset,
                });
            let page = world
                .0
                .geometry
                .device_ids_page(cursor.as_ref(), limit)
                .map_err(engine_error)?;
            Ok(WireIdsPage {
                ids: page.ids,
                next_cursor: page.next.map(|c| WireIdsCursor {
                    world_revision: c.world_revision,
                    offset: c.offset,
                }),
            })
        })
    })
}

#[derive(NifMap)]
struct WireApply {
    applied: usize,
    unchanged: usize,
    stale: usize,
    unknown_ids: usize,
    revision: u64,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn apply_health<'a>(
    env: Env<'a>,
    world: ResourceArc<WorldResource>,
    health: ResourceArc<HealthResource>,
    sequence: u64,
    rows: Term<'a>,
) -> Term<'a> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_reply(env, || {
            // Validate and bound the BEAM list before acquiring the mutable index.
            let observations: Vec<_> = crate::rows::<Observation>(rows)
                .map_err(|_| atoms::invalid_request())?
                .into_iter()
                .map(Into::into)
                .collect();
            let result = health
                .0
                .lock()
                .map_err(|_| atoms::unavailable())?
                .apply(&world.0.geometry, sequence, &observations)
                .map_err(engine_error)?;
            Ok(WireApply {
                applied: result.applied,
                unchanged: result.unchanged,
                stale: result.stale,
                unknown_ids: result.unknown_ids,
                revision: result.revision,
            })
        })
    })
}

#[derive(NifMap)]
struct WireCounts {
    healthy: u64,
    unavailable: u64,
    unknown: u64,
    observed: u64,
    total: u64,
}

impl From<HealthCounts> for WireCounts {
    fn from(c: HealthCounts) -> Self {
        Self {
            healthy: c.healthy,
            unavailable: c.unavailable,
            unknown: c.unknown,
            observed: c.observed,
            total: c.total,
        }
    }
}

#[derive(NifMap)]
struct WireGlyphHealth {
    id: String,
    counts: WireCounts,
}

#[derive(NifMap)]
struct WireTileHealth {
    world_revision: String,
    tile_revision: String,
    epoch: String,
    revision: u64,
    observation_sequence: u64,
    glyphs: Vec<WireGlyphHealth>,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tile_health(
    env: Env<'_>,
    world: ResourceArc<WorldResource>,
    health: ResourceArc<HealthResource>,
    selection: ResourceArc<SelectionResource>,
) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_reply(env, || {
            let result = health
                .0
                .lock()
                .map_err(|_| atoms::unavailable())?
                .tile_health(&world.0.geometry, &selection.0)
                .map_err(engine_error)?;
            Ok(WireTileHealth {
                world_revision: result.world_revision,
                tile_revision: result.tile_revision,
                // Epoch is an opaque identity; JSON numbers cannot preserve every u64.
                epoch: format!("{:016x}", result.epoch),
                revision: result.revision,
                observation_sequence: result.observation_sequence,
                glyphs: result
                    .glyphs
                    .into_iter()
                    .map(|g| WireGlyphHealth {
                        id: g.id,
                        counts: g.counts.into(),
                    })
                    .collect(),
            })
        })
    })
}

#[derive(NifMap)]
struct WireHealthInfo {
    epoch: String,
    revision: u64,
    observation_sequence: u64,
    observed: u64,
    total: u64,
    retained_bytes: usize,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn health_info(
    env: Env<'_>,
    world: ResourceArc<WorldResource>,
    health: ResourceArc<HealthResource>,
) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_reply(env, || {
            let info = health
                .0
                .lock()
                .map_err(|_| atoms::unavailable())?
                .info(&world.0.geometry)
                .map_err(engine_error)?;
            Ok(WireHealthInfo {
                epoch: format!("{:016x}", info.epoch),
                revision: info.revision,
                observation_sequence: info.observation_sequence,
                observed: info.observed,
                total: info.total,
                retained_bytes: info.retained_bytes,
            })
        })
    })
}
