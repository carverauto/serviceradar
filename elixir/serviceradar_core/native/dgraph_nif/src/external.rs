// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Async Rustler NIF bindings for Horizon external topology writes, pruning,
//! and bounded multi-hop read-only queries.

use rustler::{Env, Term};

use crate::abi::{CountResult, JsonResult};
use crate::external_abi::{
    ExternalUpsertResult, NifExternalSnapshotWrite, NifExternalStatusPatch,
    NifExternalUpsertStats,
};
use crate::runtime::Pool;
use crate::{dgraph_call, rejected, write_call};

#[rustler::nif]
fn upsert_external_topology(
    env: Env<'_>,
    url: String,
    snapshot: NifExternalSnapshotWrite,
    deadline_ms: u64,
) -> Term<'_> {
    let write = match snapshot.try_into_write() {
        Ok(write) => write,
        Err(reason) => return rejected(env, reason),
    };
    dgraph_call(
        env,
        url,
        Pool::Bulk,
        deadline_ms,
        move |client| async move { client.upsert_external_topology(&write).await },
        |result| match result {
            Ok(stats) => ExternalUpsertResult::Ok(NifExternalUpsertStats::from(stats)),
            Err(reason) => ExternalUpsertResult::Error(reason),
        },
    )
}

#[rustler::nif]
fn upsert_external_status(
    env: Env<'_>,
    url: String,
    patch: NifExternalStatusPatch,
    deadline_ms: u64,
) -> Term<'_> {
    let write = match patch.try_into_write() {
        Ok(write) => write,
        Err(reason) => return rejected(env, reason),
    };
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_external_status(&write).await
    })
}

#[rustler::nif]
fn prune_stale_external(
    env: Env<'_>,
    url: String,
    cutoff: String,
    deadline_ms: u64,
) -> Term<'_> {
    dgraph_call(
        env,
        url,
        Pool::Bulk,
        deadline_ms,
        move |client| async move { client.prune_stale_external(&cutoff).await },
        |result| match result {
            Ok(count) => CountResult::Ok(count as u64),
            Err(reason) => CountResult::Error(reason),
        },
    )
}

macro_rules! json_call {
    ($env:expr, $url:expr, $pool:expr, $deadline_ms:expr, $op:expr) => {
        dgraph_call(
            $env,
            $url,
            $pool,
            $deadline_ms,
            $op,
            |result| match result
                .and_then(|value| serde_json::to_string(&value).map_err(|err| err.to_string()))
            {
                Ok(json) => JsonResult::Ok(json),
                Err(reason) => JsonResult::Error(reason),
            },
        )
    };
}

#[rustler::nif]
fn query_blast_radius(
    env: Env<'_>,
    url: String,
    seed_id: String,
    max_hops: u8,
    limit: u64,
    deadline_ms: u64,
) -> Term<'_> {
    if seed_id.trim().is_empty() {
        return rejected(env, "seed_id must not be empty".to_string());
    }
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    json_call!(env, url, Pool::Item, deadline_ms, move |client| async move {
        client.query_blast_radius(&seed_id, max_hops, limit).await
    })
}

#[rustler::nif]
fn query_shared_fate_spofs(
    env: Env<'_>,
    url: String,
    min_targets: u64,
    limit: u64,
    deadline_ms: u64,
) -> Term<'_> {
    let min_targets = usize::try_from(min_targets).unwrap_or(1);
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    json_call!(env, url, Pool::Bulk, deadline_ms, move |client| async move {
        client.query_shared_fate_spofs(min_targets, limit).await
    })
}

#[rustler::nif]
fn query_customer_cone(
    env: Env<'_>,
    url: String,
    asn_id: String,
    max_hops: u8,
    limit: u64,
    deadline_ms: u64,
) -> Term<'_> {
    if asn_id.trim().is_empty() {
        return rejected(env, "asn_id must not be empty".to_string());
    }
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    json_call!(env, url, Pool::Item, deadline_ms, move |client| async move {
        client.query_customer_cone(&asn_id, max_hops, limit).await
    })
}

#[rustler::nif]
fn query_multi_hop_trace(
    env: Env<'_>,
    url: String,
    src_id: String,
    dst_id: Option<String>,
    max_hops: u8,
    limit: u64,
    deadline_ms: u64,
) -> Term<'_> {
    if src_id.trim().is_empty() {
        return rejected(env, "src_id must not be empty".to_string());
    }
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    json_call!(env, url, Pool::Item, deadline_ms, move |client| async move {
        client
            .query_multi_hop_trace(&src_id, dst_id.as_deref(), max_hops, limit)
            .await
    })
}
