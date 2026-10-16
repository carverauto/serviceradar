//! Typed BEAM boundary for the persistent membership index; no JSON intermediates.
use crate::bitmap_index::{Index, Instruction, Kind, Query, Row, Value};
use crate::core::arrow_serde::vec_into_binary;
use rustler::types::list::ListIterator;
use rustler::{Binary, Decoder, Env, NifMap, NifUnitEnum, Resource, ResourceArc, Term};

fn list<'a, T>(
    term: Term<'a>,
    cap: usize,
    decode: impl Fn(Term<'a>) -> Result<T, &'static str>,
) -> Result<Vec<T>, &'static str> {
    let values: ListIterator = term.decode().map_err(|_| "invalid_list")?;
    let mut result = Vec::new();
    for value in values {
        if result.len() == cap {
            return Err("list_budget");
        }
        result.push(decode(value)?);
    }
    Ok(result)
}
fn text(term: Term<'_>, cap: usize) -> Result<String, &'static str> {
    let bytes: Binary = term.decode().map_err(|_| "invalid_text")?;
    if bytes.len() > cap {
        return Err("text_budget");
    }
    std::str::from_utf8(bytes.as_slice())
        .map(str::to_owned)
        .map_err(|_| "invalid_text")
}
fn facets(term: Term<'_>, cap: usize) -> Result<Vec<(String, String)>, &'static str> {
    list(term, cap, |value| {
        let (key, value): (Term, Term) = value.decode().map_err(|_| "invalid_facet")?;
        Ok((text(key, 64)?, text(value, 256)?))
    })
}
fn rows(term: Term<'_>) -> Result<Vec<Row>, &'static str> {
    list(term, 500, |value| {
        let (ordinal, live, attributes): (u32, bool, Term) =
            value.decode().map_err(|_| "invalid_row")?;
        let attributes = list(attributes, 32, |attribute| {
            let (key, value): (Term, Binary) = attribute.decode().map_err(|_| "invalid_facet")?;
            let value = if value.len() > 256 {
                Value::Unavailable
            } else {
                Value::Exact(
                    std::str::from_utf8(value.as_slice())
                        .map_err(|_| "invalid_text")?
                        .to_owned(),
                )
            };
            Ok((text(key, 64)?, value))
        })?;
        Ok((ordinal, live, attributes))
    })
}
fn program(term: Term<'_>) -> Result<Vec<Instruction>, &'static str> {
    list(term, 65, |value| {
        let (op, key, value, arity): (u8, Term, Term, u16) =
            value.decode().map_err(|_| "invalid_expression")?;
        Ok((op, text(key, 64)?, text(value, 256)?, arity))
    })
}
fn ids(term: Term<'_>) -> Result<Vec<u32>, &'static str> {
    list(term, 8192, |value| {
        u32::decode(value).map_err(|_| "invalid_ordinal")
    })
}

#[derive(NifUnitEnum)]
pub enum EntityKind {
    Device,
    Interface,
}
impl From<EntityKind> for Kind {
    fn from(kind: EntityKind) -> Self {
        match kind {
            EntityKind::Device => Self::Device,
            EntityKind::Interface => Self::Interface,
        }
    }
}
pub struct BitmapIndexResource(Index);
#[rustler::resource_impl]
impl Resource for BitmapIndexResource {}
pub struct BitmapQueryResource(Query);
#[rustler::resource_impl]
impl Resource for BitmapQueryResource {}
#[derive(NifMap)]
pub struct BitmapIndexStatus<'a> {
    revision: u64,
    source_revision: Binary<'a>,
    ready: bool,
    cardinality: u64,
    native_bytes: usize,
    peak_bytes: usize,
    pins: usize,
    unavailable_facets: Vec<String>,
}
fn status(
    env: Env<'_>,
    s: crate::bitmap_index::Status,
) -> Result<BitmapIndexStatus<'_>, &'static str> {
    Ok(BitmapIndexStatus {
        revision: s.revision,
        source_revision: vec_into_binary(env, s.source).map_err(|_| "allocation_failed")?,
        ready: s.ready,
        cardinality: s.cardinality,
        native_bytes: s.native_bytes,
        peak_bytes: s.peak_bytes,
        pins: s.pins,
        unavailable_facets: s.unavailable,
    })
}
#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_index_new(
    dictionary_epoch: Binary<'_>,
    index_epoch: Binary<'_>,
    kind: EntityKind,
    supported: Term<'_>,
) -> Result<ResourceArc<BitmapIndexResource>, &'static str> {
    let dictionary = dictionary_epoch
        .as_slice()
        .try_into()
        .map_err(|_| "invalid_epoch")?;
    let epoch = index_epoch
        .as_slice()
        .try_into()
        .map_err(|_| "invalid_epoch")?;
    Ok(ResourceArc::new(BitmapIndexResource(Index::new(
        dictionary,
        epoch,
        kind.into(),
        list(supported, 32, |value| text(value, 64))?,
    )?)))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_index_publish<'a>(
    env: Env<'a>,
    index: ResourceArc<BitmapIndexResource>,
    expected_revision: u64,
    source_revision: Binary<'a>,
    current_rows: Term<'a>,
    ready: bool,
) -> Result<BitmapIndexStatus<'a>, &'static str> {
    status(
        env,
        index.0.publish(
            expected_revision,
            source_revision.as_slice(),
            rows(current_rows)?,
            ready,
        )?,
    )
}
#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_index_status(
    env: Env<'_>,
    index: ResourceArc<BitmapIndexResource>,
) -> Result<BitmapIndexStatus<'_>, &'static str> {
    status(env, index.0.status()?)
}
#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_index_query<'a>(
    env: Env<'a>,
    index: ResourceArc<BitmapIndexResource>,
    dictionary_epoch: Binary<'_>,
    index_epoch: Binary<'_>,
    kind: EntityKind,
    authority: Binary<'_>,
    expression: Term<'_>,
    timeout_ms: u64,
) -> Result<(ResourceArc<BitmapQueryResource>, u64, Binary<'a>, u64), &'static str> {
    index.0.check_identity(
        dictionary_epoch.as_slice(),
        index_epoch.as_slice(),
        kind.into(),
    )?;
    let (query, revision, source, count) =
        index
            .0
            .query(authority.as_slice(), &program(expression)?, timeout_ms)?;
    Ok((
        ResourceArc::new(BitmapQueryResource(query)),
        revision,
        vec_into_binary(env, source).map_err(|_| "allocation_failed")?,
        count,
    ))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_query_page(
    query: ResourceArc<BitmapQueryResource>,
    authority: Binary<'_>,
    after: u32,
    limit: usize,
    timeout_ms: u64,
) -> Result<Vec<u32>, &'static str> {
    query.0.page(authority.as_slice(), after, limit, timeout_ms)
}
#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_query_facets(
    query: ResourceArc<BitmapQueryResource>,
    authority: Binary<'_>,
    requested: Term<'_>,
    timeout_ms: u64,
) -> Result<Vec<u64>, &'static str> {
    query
        .0
        .facets(authority.as_slice(), &facets(requested, 50)?, timeout_ms)
}
#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_query_view<'a>(
    env: Env<'a>,
    query: ResourceArc<BitmapQueryResource>,
    authority: Binary<'a>,
    ordinals: Term<'a>,
    timeout_ms: u64,
) -> Result<Binary<'a>, &'static str> {
    let bitmap = query
        .0
        .view(authority.as_slice(), &ids(ordinals)?, timeout_ms)?;
    let mut bytes = Vec::with_capacity(bitmap.serialized_size());
    bitmap
        .serialize_into(&mut bytes)
        .map_err(|_| "serialization_failed")?;
    vec_into_binary(env, bytes).map_err(|_| "allocation_failed")
}
#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_query_intersection_count(
    query: ResourceArc<BitmapQueryResource>,
    authority: Binary<'_>,
    dictionary_epoch: Binary<'_>,
    index_epoch: Binary<'_>,
    kind: EntityKind,
    bitmap: Binary<'_>,
    timeout_ms: u64,
) -> Result<u64, &'static str> {
    query.0.count_serialized(
        authority.as_slice(),
        dictionary_epoch.as_slice(),
        index_epoch.as_slice(),
        kind.into(),
        bitmap.as_slice(),
        timeout_ms,
    )
}
#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_query_close(query: ResourceArc<BitmapQueryResource>) -> Result<(), &'static str> {
    query.0.close()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_index_close(index: ResourceArc<BitmapIndexResource>) -> Result<(), &'static str> {
    index.0.close()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bitmap_query_view_sets<'a>(
    env: Env<'a>,
    query: ResourceArc<BitmapQueryResource>,
    authority: Binary<'a>,
    ordinals: Term<'a>,
    requested: Term<'a>,
    timeout_ms: u64,
) -> Result<Vec<Binary<'a>>, &'static str> {
    let sets = query.0.view_sets(
        authority.as_slice(),
        &ids(ordinals)?,
        &facets(requested, 16)?,
        timeout_ms,
    )?;
    sets.into_iter()
        .map(|set| {
            let mut bytes = Vec::with_capacity(set.serialized_size());
            set.serialize_into(&mut bytes)
                .map_err(|_| "serialization_failed")?;
            vec_into_binary(env, bytes).map_err(|_| "allocation_failed")
        })
        .collect()
}
