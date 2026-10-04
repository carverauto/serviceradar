//! Bounded Rustler boundary for persisted topology worlds. Builders and source
//! snapshots are single-use; candidates and installed worlds are immutable.

#[cfg(panic = "abort")]
compile_error!("topology_atlas_nif requires panic=unwind to contain native panics");

mod admission;
mod async_read;
mod details;
mod health;
mod model;
#[cfg(test)]
mod tests;

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use dgraph_topology::TopologyView;
use rustler::{
    types::list::ListIterator, Atom, Decoder, Encoder, Env, NifMap, NifUnitEnum, Resource,
    ResourceArc, Term,
};
use serviceradar_topology_atlas::{Budget, Cell, Glyph, GlyphKind, Tile, TileProfile};
use tokio::runtime::Runtime;

use model::{
    Builder, Candidate, Info, InventoryRow, PipelineStats, PositionRow, RelationRow, Result,
    SourceGraph, WorldState, PAGE_LIMIT,
};

mod atoms {
    rustler::atoms! {ok, error, not_found, items, next_cursor, device, aggregate, boundary,
    insert_positions, update_positions, activate_device_ids, deactivate_device_ids,
    upsert_relations, deactivate_relation_ids}
}

struct BuilderResource(Mutex<Option<Builder>>);
struct GraphResource(Mutex<Option<TopologyView>>);
struct WorldResource(Arc<WorldState>);
struct CandidateResource(Candidate);

#[rustler::resource_impl]
impl Resource for BuilderResource {
    fn destructor(self, _env: Env<'_>) {
        reclaim(self);
    }
}
#[rustler::resource_impl]
impl Resource for GraphResource {
    fn destructor(self, _env: Env<'_>) {
        reclaim(self);
    }
}
#[rustler::resource_impl]
impl Resource for WorldResource {
    fn destructor(self, _env: Env<'_>) {
        reclaim(self);
    }
}
#[rustler::resource_impl]
impl Resource for CandidateResource {
    fn destructor(self, _env: Env<'_>) {
        reclaim(self);
    }
}

// Resource collection can happen on a normal BEAM scheduler. Releasing millions
// of strings belongs on the native blocking pool, just like constructing them.
// Both entry points initialize RUNTIME before allocating any large resource.
static RETIRING: AtomicUsize = AtomicUsize::new(0);

fn reclaim<T: Send + 'static>(value: T) {
    if let Some(runtime) = RUNTIME.get() {
        if RETIRING
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < 2).then_some(count + 1)
            })
            .is_ok()
        {
            runtime.spawn_blocking(move || {
                drop(value);
                RETIRING.fetch_sub(1, Ordering::Release);
            });
            return;
        }
    }
    // Under overload, free inline rather than queue unbounded retired worlds.
    // Normal publication/cache turnover admits at most two concurrent releases.
    drop(value);
}

fn isolate<T>(call: impl FnOnce() -> Result<T>) -> Result<T> {
    catch_unwind(AssertUnwindSafe(call))
        .unwrap_or_else(|_| Err("topology atlas call failed".into()))
}

fn reply<'a, T: Encoder>(env: Env<'a>, result: Result<T>) -> Term<'a> {
    match result {
        Ok(value) => (atoms::ok(), value).encode(env),
        Err(reason) => (atoms::error(), reason).encode(env),
    }
}

fn ack(env: Env<'_>, result: Result<()>) -> Term<'_> {
    match result {
        Ok(()) => atoms::ok().encode(env),
        Err(reason) => (atoms::error(), reason).encode(env),
    }
}

// Stop before decoding row 501. A caller cannot make one import copy an entire
// BEAM graph into Rust before the limit is checked. Improper lists fail inside
// the panic boundary without touching the builder.
fn rows<'a, T: Decoder<'a>>(term: Term<'a>) -> Result<Vec<T>> {
    let list: ListIterator<'a> = term.decode().map_err(|_| "rows must be a list")?;
    let mut values = Vec::new();
    for item in list {
        if values.len() == PAGE_LIMIT {
            return Err("page exceeds 500 rows".into());
        }
        values.push(item.decode().map_err(|_| "invalid row")?);
    }
    Ok(values)
}

fn take<T>(resource: &Mutex<Option<T>>) -> Result<T> {
    resource
        .lock()
        .map_err(|_| "resource unavailable")?
        .take()
        .ok_or_else(|| "resource already consumed".into())
}

#[rustler::nif]
fn algorithm_version() -> String {
    serviceradar_topology_atlas::ALGORITHM.into()
}

#[rustler::nif(schedule = "DirtyIo")]
fn new_builder(env: Env<'_>, layout_version: String, zmax: u8) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        reply(
            env,
            isolate(|| {
                runtime()?;
                Ok(ResourceArc::new(BuilderResource(Mutex::new(Some(
                    Builder::new(layout_version, zmax)?,
                )))))
            }),
        )
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn add_positions<'a>(
    env: Env<'a>,
    builder: ResourceArc<BuilderResource>,
    input: Term<'a>,
) -> Term<'a> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        ack(
            env,
            isolate(|| {
                let rows = rows::<PositionRow>(input)?;
                builder
                    .0
                    .lock()
                    .map_err(|_| "resource unavailable")?
                    .as_mut()
                    .ok_or("resource already consumed")?
                    .add_positions(rows)
            }),
        )
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn add_relations<'a>(
    env: Env<'a>,
    builder: ResourceArc<BuilderResource>,
    input: Term<'a>,
) -> Term<'a> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        ack(
            env,
            isolate(|| {
                let rows = rows::<RelationRow>(input)?;
                builder
                    .0
                    .lock()
                    .map_err(|_| "resource unavailable")?
                    .as_mut()
                    .ok_or("resource already consumed")?
                    .add_relations(rows)
            }),
        )
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn add_inventory<'a>(
    env: Env<'a>,
    builder: ResourceArc<BuilderResource>,
    input: Term<'a>,
) -> Term<'a> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        ack(
            env,
            isolate(|| {
                let rows = rows::<InventoryRow>(input)?;
                builder
                    .0
                    .lock()
                    .map_err(|_| "resource unavailable")?
                    .as_mut()
                    .ok_or("resource already consumed")?
                    .add_inventory(rows)
            }),
        )
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn finish_world(env: Env<'_>, builder: ResourceArc<BuilderResource>) -> Term<'_> {
    crate::admission::call(env, &crate::admission::WORLD_BUILD, || {
        reply(
            env,
            isolate(|| Ok(ResourceArc::new(WorldResource(take(&builder.0)?.finish()?)))),
        )
    })
}

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

fn runtime() -> Result<&'static Runtime> {
    if let Some(runtime) = RUNTIME.get() {
        return Ok(runtime);
    }
    let built = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .max_blocking_threads(2)
        .thread_name("topology-atlas")
        .build()
        .map_err(|_| "graph runtime unavailable")?;
    let _ = RUNTIME.set(built);
    RUNTIME
        .get()
        .ok_or_else(|| "graph runtime unavailable".into())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reconcile(
    env: Env<'_>,
    builder: ResourceArc<BuilderResource>,
    graph: ResourceArc<GraphResource>,
) -> Term<'_> {
    crate::admission::call(env, &crate::admission::WORLD_BUILD, || {
        reply(
            env,
            isolate(|| {
                let builder = take(&builder.0)?;
                let source = SourceGraph::from_view(take(&graph.0)?)?;
                Ok(ResourceArc::new(CandidateResource(
                    builder.reconcile(source)?,
                )))
            }),
        )
    })
}

#[derive(NifMap)]
struct CandidateInfo {
    world: ResourceArc<WorldResource>,
    source_digest: String,
    layout_version: String,
    zmax: u8,
    algorithm_version: String,
    extent: u32,
    node_count: u64,
    relation_count: u64,
    pipeline_stats: PipelineStats,
}

#[rustler::nif]
fn candidate_info(env: Env<'_>, candidate: ResourceArc<CandidateResource>) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        let info = &candidate.0.world.info;
        reply(
            env,
            Ok(CandidateInfo {
                world: ResourceArc::new(WorldResource(candidate.0.world.clone())),
                source_digest: candidate.0.source_digest.clone(),
                layout_version: info.layout_version.clone(),
                zmax: info.zmax,
                algorithm_version: info.algorithm_version.clone(),
                extent: info.extent,
                node_count: info.node_count,
                relation_count: info.relation_count,
                pipeline_stats: candidate.0.pipeline_stats.clone(),
            }),
        )
    })
}

#[rustler::nif]
fn world_info(env: Env<'_>, world: ResourceArc<WorldResource>) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        reply::<Info>(env, Ok(world.0.info.clone()))
    })
}

#[derive(NifUnitEnum)]
enum WireTileProfile {
    Standard,
    AggregateOnly,
}

#[derive(NifMap)]
struct TileBudget {
    profile: WireTileProfile,
    nodes: usize,
    edges: usize,
}
#[derive(NifMap)]
struct WireCell {
    z: u8,
    x: u32,
    y: u32,
}
#[derive(NifMap)]
struct WireGlyph {
    id: String,
    label: String,
    x: f64,
    y: f64,
    count: u64,
    kind: Atom,
}
impl From<Glyph> for WireGlyph {
    fn from(glyph: Glyph) -> Self {
        Self {
            id: glyph.id,
            label: glyph.label,
            x: glyph.x,
            y: glyph.y,
            count: glyph.count,
            kind: match glyph.kind {
                GlyphKind::Device => atoms::device(),
                GlyphKind::Aggregate => atoms::aggregate(),
                GlyphKind::Boundary => atoms::boundary(),
            },
        }
    }
}
#[derive(NifMap)]
struct WireEdge {
    id: String,
    source: u32,
    target: u32,
    count: u64,
    topology_class: String,
    stale: bool,
    start: f64,
    end: f64,
}
#[derive(NifMap)]
struct WireTile {
    profile: WireTileProfile,
    cell: WireCell,
    revision: String,
    glyphs: Vec<WireGlyph>,
    edges: Vec<WireEdge>,
    device_count: u64,
    internal_relations: u64,
    candidate_relations: usize,
    selection: ResourceArc<details::SelectionResource>,
    selection_bytes: usize,
}

impl From<Tile> for WireTile {
    fn from(tile: Tile) -> Self {
        let selection_bytes = tile.selection.retained_bytes();
        Self {
            profile: match tile.profile {
                TileProfile::Standard => WireTileProfile::Standard,
                TileProfile::AggregateOnly => WireTileProfile::AggregateOnly,
            },
            selection: ResourceArc::new(details::SelectionResource(tile.selection)),
            selection_bytes,
            cell: WireCell {
                z: tile.cell.z,
                x: tile.cell.x,
                y: tile.cell.y,
            },
            revision: tile.revision,
            glyphs: tile.glyphs.into_iter().map(Into::into).collect(),
            edges: tile
                .edges
                .into_iter()
                .map(|e| WireEdge {
                    id: e.id,
                    source: e.source,
                    target: e.target,
                    count: e.count,
                    topology_class: e.topology_class.as_str().into(),
                    stale: e.stale,
                    start: e.start,
                    end: e.end,
                })
                .collect(),
            device_count: tile.device_count,
            internal_relations: tile.internal_relations,
            candidate_relations: tile.candidate_relations,
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tile(
    env: Env<'_>,
    world: ResourceArc<WorldResource>,
    z: u8,
    x: u32,
    y: u32,
    budget: TileBudget,
) -> Term<'_> {
    crate::admission::call(env, &crate::admission::TILE_READ, || {
        details::read_reply(env, || {
            // Callers may reduce a budget, but cannot request unbounded ABI output.
            if budget.nodes > 128 || budget.edges > Budget::default().edges {
                return Err(details::engine_error(
                    serviceradar_topology_atlas::Error::InvalidBudget,
                ));
            }
            let cell = Cell::new(z, x, y).map_err(details::engine_error)?;
            let profile = match budget.profile {
                WireTileProfile::Standard => TileProfile::Standard,
                WireTileProfile::AggregateOnly => TileProfile::AggregateOnly,
            };
            let tile = world
                .0
                .geometry
                .tile_with_routing_budget(
                    cell,
                    Budget {
                        nodes: budget.nodes,
                        edges: budget.edges,
                    },
                    profile,
                    Budget::default(),
                )
                .map_err(details::engine_error)?;
            Ok(WireTile::from(tile))
        })
    })
}

#[rustler::nif]
fn search(env: Env<'_>, world: ResourceArc<WorldResource>, id: String) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        match world.0.geometry.search(&id) {
            Some(position) => (
                atoms::ok(),
                PositionRow::from_position(position.clone(), true),
            )
                .encode(env),
            None => (atoms::error(), atoms::not_found()).encode(env),
        }
    })
}

fn page<'a, T: Encoder>(
    env: Env<'a>,
    source: &[T],
    cursor: usize,
    limit: usize,
) -> Result<Term<'a>> {
    let (range, next) = model::page_range(source.len(), cursor, limit)?;
    page_map(env, source[range].encode(env), next)
}

fn indexed_page<'a, T: Encoder>(
    env: Env<'a>,
    source: &[T],
    indexes: &[usize],
    cursor: usize,
    limit: usize,
) -> Result<Term<'a>> {
    let (range, next) = model::page_range(indexes.len(), cursor, limit)?;
    let items: Vec<_> = indexes[range]
        .iter()
        .map(|&i| source[i].encode(env))
        .collect();
    page_map(env, items.encode(env), next)
}

fn page_map<'a>(env: Env<'a>, items: Term<'a>, next: Option<usize>) -> Result<Term<'a>> {
    Term::map_from_arrays(
        env,
        &[atoms::items(), atoms::next_cursor()],
        &[items, next.encode(env)],
    )
    .map_err(|_| "cannot encode page".into())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn positions_page(
    env: Env<'_>,
    candidate: ResourceArc<CandidateResource>,
    cursor: usize,
    limit: usize,
) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        reply(
            env,
            isolate(|| page(env, &candidate.0.positions, cursor, limit)),
        )
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn relations_page(
    env: Env<'_>,
    candidate: ResourceArc<CandidateResource>,
    cursor: usize,
    limit: usize,
) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        reply(
            env,
            isolate(|| page(env, &candidate.0.relations, cursor, limit)),
        )
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn delta_page(
    env: Env<'_>,
    candidate: ResourceArc<CandidateResource>,
    operation: Atom,
    cursor: usize,
    limit: usize,
) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        reply(
            env,
            isolate(|| {
                let c = &candidate.0;
                let d = &c.deltas;
                if operation == atoms::insert_positions() {
                    indexed_page(env, &c.positions, &d.insert_positions, cursor, limit)
                } else if operation == atoms::update_positions() {
                    page(env, &d.update_positions, cursor, limit)
                } else if operation == atoms::activate_device_ids() {
                    page(env, &d.activate_device_ids, cursor, limit)
                } else if operation == atoms::deactivate_device_ids() {
                    page(env, &d.deactivate_device_ids, cursor, limit)
                } else if operation == atoms::upsert_relations() {
                    indexed_page(env, &c.relations, &d.upsert_relations, cursor, limit)
                } else if operation == atoms::deactivate_relation_ids() {
                    page(env, &d.deactivate_relation_ids, cursor, limit)
                } else {
                    Err("invalid delta operation".into())
                }
            }),
        )
    })
}

rustler::init!("Elixir.ServiceRadar.TopologyAtlas.Native");
