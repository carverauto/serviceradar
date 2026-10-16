//! Bounded canonical dictionary projection paired with a world generation.
use std::sync::RwLock;

use rustler::{
    types::list::ListIterator, Atom, Binary, Env, NifMap, OwnedBinary, Resource, ResourceArc, Term,
};
use serviceradar_topology_atlas::{CanonicalOrdinals, Error, OrdinalInfo};

use crate::details::{read_reply, AggregateResource};
use crate::WorldResource;

mod atoms {
    rustler::atoms! {busy, invalid_request, invalid_epoch, stale_revision, not_ready, sealed, bitmap_budget, deadline_exceeded, unavailable}
}

// Admission follows allocated resource lifetime, including old query receipts
// and asynchronous destruction, rather than ending when the builder NIF returns.
static ORDINAL_RESOURCES: crate::admission::Gate = crate::admission::Gate::new(2);

struct OrdinalResource {
    mapping: RwLock<CanonicalOrdinals>,
    // Fields drop in order: the mapping allocation is freed before its permit.
    _lifetime: crate::admission::Permit<'static>,
}
#[rustler::resource_impl]
impl Resource for OrdinalResource {
    fn destructor(self, _env: Env<'_>) {
        crate::reclaim(self);
    }
}

fn engine_error(error: Error) -> Atom {
    match error {
        Error::StaleDetailRevision => atoms::stale_revision(),
        Error::OrdinalMappingNotReady => atoms::not_ready(),
        Error::OrdinalMappingSealed => atoms::sealed(),
        Error::OrdinalBudgetExceeded => atoms::bitmap_budget(),
        Error::DeadlineExceeded => atoms::deadline_exceeded(),
        _ => atoms::invalid_request(),
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Result<Binary<'a>, Atom> {
    let mut binary = OwnedBinary::new(bytes.len()).ok_or_else(atoms::unavailable)?;
    binary.as_mut_slice().copy_from_slice(bytes);
    Ok(binary.release(env))
}

#[derive(NifMap)]
struct WireInfo<'a> {
    world_revision: String,
    dictionary_epoch: Binary<'a>,
    ready: bool,
    mapped: usize,
    total: usize,
    retained_bytes: usize,
}

fn info(env: Env<'_>, row: OrdinalInfo) -> Result<WireInfo<'_>, Atom> {
    Ok(WireInfo {
        world_revision: row.world_revision,
        dictionary_epoch: binary(env, &row.dictionary_epoch)?,
        ready: row.ready,
        mapped: row.mapped,
        total: row.total,
        retained_bytes: row.retained_bytes,
    })
}

fn uid(term: Term<'_>) -> Result<String, Atom> {
    let value: Binary = term.decode().map_err(|_| atoms::invalid_request())?;
    if value.is_empty() || value.len() > 256 {
        return Err(atoms::invalid_request());
    }
    std::str::from_utf8(value.as_slice())
        .map(str::to_owned)
        .map_err(|_| atoms::invalid_request())
}

fn bounded_list<'a, T>(
    term: Term<'a>,
    limit: usize,
    decode: impl Fn(Term<'a>) -> Result<T, Atom>,
) -> Result<Vec<T>, Atom> {
    let list: ListIterator = term.decode().map_err(|_| atoms::invalid_request())?;
    let mut values = Vec::new();
    for value in list {
        if values.len() == limit {
            return Err(atoms::bitmap_budget());
        }
        values.push(decode(value)?);
    }
    Ok(values)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn new_ordinals<'a>(
    env: Env<'a>,
    world: ResourceArc<WorldResource>,
    dictionary_epoch: Binary<'a>,
) -> Term<'a> {
    crate::admission::call(env, &crate::admission::ORDINAL_BUILD, || {
        read_reply(env, || {
            let epoch = dictionary_epoch
                .as_slice()
                .try_into()
                .map_err(|_| atoms::invalid_epoch())?;
            let lifetime = ORDINAL_RESOURCES.try_acquire().ok_or_else(atoms::busy)?;
            let mapping = CanonicalOrdinals::new(&world.0.geometry, epoch).map_err(engine_error)?;
            Ok(ResourceArc::new(OrdinalResource {
                mapping: RwLock::new(mapping),
                _lifetime: lifetime,
            }))
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn apply_ordinals<'a>(
    env: Env<'a>,
    world: ResourceArc<WorldResource>,
    mapping: ResourceArc<OrdinalResource>,
    rows: Term<'a>,
) -> Term<'a> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_reply(env, || {
            let rows = bounded_list(rows, 500, |row| {
                let (id, ordinal): (Term, u32) =
                    row.decode().map_err(|_| atoms::invalid_request())?;
                Ok((uid(id)?, ordinal))
            })?;
            let result = mapping
                .mapping
                .try_write()
                .map_err(|_| atoms::busy())?
                .apply(&world.0.geometry, &rows)
                .map_err(engine_error)?;
            info(env, result)
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn seal_ordinals(
    env: Env<'_>,
    world: ResourceArc<WorldResource>,
    mapping: ResourceArc<OrdinalResource>,
) -> Term<'_> {
    read_reply(env, || {
        let result = mapping
            .mapping
            .try_write()
            .map_err(|_| atoms::busy())?
            .seal(&world.0.geometry)
            .map_err(engine_error)?;
        info(env, result)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ordinal_info(
    env: Env<'_>,
    world: ResourceArc<WorldResource>,
    mapping: ResourceArc<OrdinalResource>,
) -> Term<'_> {
    read_reply(env, || {
        let result = mapping
            .mapping
            .try_read()
            .map_err(|_| atoms::busy())?
            .info(&world.0.geometry)
            .map_err(engine_error)?;
        info(env, result)
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn device_ordinals<'a>(
    env: Env<'a>,
    world: ResourceArc<WorldResource>,
    mapping: ResourceArc<OrdinalResource>,
    ids: Term<'a>,
) -> Term<'a> {
    crate::admission::call(env, &crate::admission::BOUNDED_READ, || {
        read_reply(env, || {
            let ids = bounded_list(ids, 8192, uid)?;
            mapping
                .mapping
                .try_read()
                .map_err(|_| atoms::busy())?
                .device_ordinals(&world.0.geometry, &ids)
                .map_err(engine_error)
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn aggregate_ordinals(
    env: Env<'_>,
    world: ResourceArc<WorldResource>,
    mapping: ResourceArc<OrdinalResource>,
    aggregate: ResourceArc<AggregateResource>,
    max_bytes: usize,
    timeout_ms: u64,
) -> Term<'_> {
    crate::admission::call(env, &crate::admission::ORDINAL_READ, || {
        read_reply(env, || {
            let bytes = mapping
                .mapping
                .try_read()
                .map_err(|_| atoms::busy())?
                .aggregate(&world.0.geometry, &aggregate.0, max_bytes, timeout_ms)
                .map_err(engine_error)?;
            binary(env, &bytes)
        })
    })
}
