//! Opaque selection resources contain bounded descriptors, never a World Arc.
//! The serving owner additionally fences these reads by publication generation.

use std::panic::{catch_unwind, AssertUnwindSafe};

use rustler::{Atom, Encoder, Env, NifMap, NifTaggedEnum, Resource, ResourceArc, Term};
use serviceradar_topology_atlas::{
    AggregateSelection, DetailCursor, DetailScope, Error, RelationCursor, TileSelection,
};

use crate::model::{PositionRow, RelationRow};
use crate::WorldResource;

mod atoms {
    rustler::atoms! {ok, error, not_found, invalid_cursor, invalid_request, stale_revision, unavailable, selection_budget_exceeded}
}

pub(crate) struct SelectionResource(pub TileSelection);
struct AggregateResource(AggregateSelection);
#[rustler::resource_impl]
impl Resource for SelectionResource {}
#[rustler::resource_impl]
impl Resource for AggregateResource {}

pub(crate) fn engine_error(error: Error) -> Atom {
    match error {
        Error::SelectionBudgetExceeded => atoms::selection_budget_exceeded(),
        Error::DetailNotFound => atoms::not_found(),
        Error::InvalidDetailCursor => atoms::invalid_cursor(),
        Error::StaleDetailRevision => atoms::stale_revision(),
        _ => atoms::invalid_request(),
    }
}

pub(crate) fn read_reply<'a, T: Encoder>(
    env: Env<'a>,
    call: impl FnOnce() -> Result<T, Atom>,
) -> Term<'a> {
    match catch_unwind(AssertUnwindSafe(call)) {
        Ok(Ok(value)) => (atoms::ok(), value).encode(env),
        Ok(Err(reason)) => (atoms::error(), reason).encode(env),
        Err(_) => (atoms::error(), atoms::unavailable()).encode(env),
    }
}

fn read_call<'a, T: Encoder>(env: Env<'a>, call: impl FnOnce() -> Result<T, Error>) -> Term<'a> {
    read_reply(env, || call().map_err(engine_error))
}

#[derive(NifTaggedEnum)]
enum Scope {
    Neighborhood(String),
    ComponentMembers(String),
    AggregateMembers(ResourceArc<AggregateResource>),
}

impl Scope {
    fn owned(self) -> DetailScope {
        match self {
            Self::Neighborhood(id) => DetailScope::Neighborhood(id),
            Self::ComponentMembers(id) => DetailScope::ComponentMembers(id),
            Self::AggregateMembers(selection) => DetailScope::AggregateMembers(selection.0.clone()),
        }
    }
}

#[derive(NifMap)]
struct WireDetailCursor {
    world_revision: String,
    scope_revision: String,
    node_page: u32,
    edge_page: u32,
}

impl From<DetailCursor> for WireDetailCursor {
    fn from(c: DetailCursor) -> Self {
        Self {
            world_revision: c.world_revision,
            scope_revision: c.scope_revision,
            node_page: c.node_page,
            edge_page: c.edge_page,
        }
    }
}
impl From<WireDetailCursor> for DetailCursor {
    fn from(c: WireDetailCursor) -> Self {
        Self {
            world_revision: c.world_revision,
            scope_revision: c.scope_revision,
            node_page: c.node_page,
            edge_page: c.edge_page,
        }
    }
}

#[derive(NifMap)]
struct WireDetailRelation {
    id: String,
    source: u32,
    target: u32,
    evidence_class: Option<String>,
    role: Option<String>,
}
#[derive(NifMap)]
struct WireDetailPage {
    world_revision: String,
    scope_revision: String,
    nodes: Vec<PositionRow>,
    relations: Vec<WireDetailRelation>,
    total_members: u64,
    selected_relations: u64,
    incident_relations: Option<u64>,
    next_cursor: Option<WireDetailCursor>,
}

#[derive(NifMap)]
struct WireAggregateInfo {
    member_count: usize,
    retained_bytes: usize,
}

#[rustler::nif]
fn aggregate_info(env: Env<'_>, aggregate: ResourceArc<AggregateResource>) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_reply(env, || {
            Ok(WireAggregateInfo {
                member_count: aggregate.0.member_count(),
                retained_bytes: aggregate.0.retained_bytes(),
            })
        })
    })
}

#[derive(NifMap)]
struct WireRelationDetail {
    relation: RelationRow,
    nodes: Vec<PositionRow>,
}

fn relation_row<'a>(world: &'a WorldResource, id: &str) -> Result<&'a RelationRow, Error> {
    // Both cold-load and reconciliation collect a BTreeMap into this immutable
    // slice, preserving canonical relation-ID order.
    world
        .0
        .relations
        .binary_search_by(|row| row.relation_id.as_str().cmp(id))
        .map(|index| &world.0.relations[index])
        .map_err(|_| Error::DetailNotFound)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn relation(env: Env<'_>, world: ResourceArc<WorldResource>, id: String) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_call(env, || {
            let row = relation_row(&world, &id)?;
            let mut nodes = Vec::with_capacity(2);
            for endpoint in [&row.source_id, &row.target_id] {
                let position = world
                    .0
                    .geometry
                    .search(endpoint)
                    .ok_or(Error::StaleDetailRevision)?;
                nodes.push(PositionRow::from_position(position.clone(), true));
            }
            Ok(WireRelationDetail {
                relation: row.clone(),
                nodes,
            })
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn aggregate_selection(
    env: Env<'_>,
    world: ResourceArc<WorldResource>,
    selection: ResourceArc<SelectionResource>,
    glyph_id: String,
) -> Term<'_> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_call(env, || {
            Ok(ResourceArc::new(AggregateResource(
                world
                    .0
                    .geometry
                    .aggregate_selection(&selection.0, &glyph_id)?,
            )))
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn detail<'a>(
    env: Env<'a>,
    world: ResourceArc<WorldResource>,
    scope: Term<'a>,
    cursor: Term<'a>,
) -> Term<'a> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_call(env, || {
            let scope = scope
                .decode::<Scope>()
                .map_err(|_| Error::InvalidIdentity)?
                .owned();
            let cursor: Option<DetailCursor> = cursor
                .decode::<Option<WireDetailCursor>>()
                .map_err(|_| Error::InvalidDetailCursor)?
                .map(Into::into);
            let page = world.0.geometry.detail(&scope, cursor.as_ref())?;
            let relations = page
                .relations
                .into_iter()
                .map(|edge| {
                    let row = relation_row(&world, &edge.id)?;
                    Ok(WireDetailRelation {
                        id: edge.id,
                        source: edge.source,
                        target: edge.target,
                        evidence_class: row.evidence_class.clone(),
                        role: row.role.clone(),
                    })
                })
                .collect::<Result<Vec<_>, Error>>()?;
            Ok(WireDetailPage {
                world_revision: page.world_revision,
                scope_revision: page.scope_revision,
                nodes: page
                    .nodes
                    .into_iter()
                    .map(|p| PositionRow::from_position(p, true))
                    .collect(),
                relations,
                total_members: page.total_members,
                selected_relations: page.selected_relations,
                incident_relations: page.incident_relations,
                next_cursor: page.next.map(Into::into),
            })
        })
    })
}

#[derive(NifMap)]
struct WireRelationCursor {
    world_revision: String,
    tile_revision: String,
    offset: usize,
}
impl From<RelationCursor> for WireRelationCursor {
    fn from(c: RelationCursor) -> Self {
        Self {
            world_revision: c.world_revision,
            tile_revision: c.tile_revision,
            offset: c.offset,
        }
    }
}
impl From<WireRelationCursor> for RelationCursor {
    fn from(c: WireRelationCursor) -> Self {
        Self {
            world_revision: c.world_revision,
            tile_revision: c.tile_revision,
            offset: c.offset,
        }
    }
}

#[derive(NifMap)]
struct WireSelectedRelation {
    relation_id: String,
    source_id: String,
    target_id: String,
    evidence_class: Option<String>,
    role: Option<String>,
    source_if_index: Option<i32>,
    source_if_name: Option<String>,
    target_if_index: Option<i32>,
    target_if_name: Option<String>,
    source_interface_degree: u32,
    target_interface_degree: u32,
    rendered_edge_id: String,
    source_glyph: u32,
    target_glyph: u32,
    reversed: bool,
    bundle_members: u64,
}

impl WireSelectedRelation {
    fn new(
        row: &RelationRow,
        degrees: [u32; 2],
        selected: serviceradar_topology_atlas::SelectedRelation,
    ) -> Self {
        Self {
            relation_id: row.relation_id.clone(),
            source_id: row.source_id.clone(),
            target_id: row.target_id.clone(),
            evidence_class: row.evidence_class.clone(),
            role: row.role.clone(),
            source_if_index: row.source_if_index,
            source_if_name: row.source_if_name.clone(),
            target_if_index: row.target_if_index,
            target_if_name: row.target_if_name.clone(),
            source_interface_degree: degrees[0],
            target_interface_degree: degrees[1],
            rendered_edge_id: selected.rendered_edge_id,
            source_glyph: selected.source_glyph,
            target_glyph: selected.target_glyph,
            reversed: selected.reversed,
            bundle_members: selected.bundle_members,
        }
    }
}

#[derive(NifMap)]
struct WireRelationPage {
    relations: Vec<WireSelectedRelation>,
    total_rendered_relations: u64,
    candidates: usize,
    next_cursor: Option<WireRelationCursor>,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tile_relations<'a>(
    env: Env<'a>,
    world: ResourceArc<WorldResource>,
    selection: ResourceArc<SelectionResource>,
    cursor: Term<'a>,
    limit: usize,
) -> Term<'a> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_call(env, || {
            let cursor: Option<RelationCursor> = cursor
                .decode::<Option<WireRelationCursor>>()
                .map_err(|_| Error::InvalidDetailCursor)?
                .map(Into::into);
            let page = world
                .0
                .geometry
                .tile_relations(&selection.0, cursor.as_ref(), limit)?;
            let mut relations = Vec::with_capacity(page.relations.len());
            for selected in page.relations {
                let row = world
                    .0
                    .relations
                    .get(selected.relation_index as usize)
                    .ok_or(Error::StaleDetailRevision)?;
                if row.relation_id != selected.relation_id {
                    return Err(Error::StaleDetailRevision);
                }
                let degrees = world
                    .0
                    .interface_degrees
                    .get(selected.relation_index as usize)
                    .copied()
                    .ok_or(Error::StaleDetailRevision)?;
                relations.push(WireSelectedRelation::new(row, degrees, selected));
            }
            Ok(WireRelationPage {
                relations,
                total_rendered_relations: page.total_rendered_relations,
                candidates: page.candidates,
                next_cursor: page.next.map(Into::into),
            })
        })
    })
}
