// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Thin Rustler ABI over `dgraph_topology`. Typed `NifMap` writes and a
//! read-only DQL escape hatch.
//!
//! Every operation is asynchronous (see `call`): the NIF returns
//! `{:ok, ref, handle}` (or `{:error, reason}` for input it rejects without
//! contacting Dgraph) on a normal scheduler, and the result arrives later as a
//! message. `ServiceRadar.Dgraph` is the only caller; it waits for the reply,
//! cancels on its own deadline, and retries idempotent writes.

#[cfg(panic = "abort")]
compile_error!("dgraph_nif requires panic=unwind to contain native panics");

mod abi;
mod call;
mod external;
mod external_abi;
mod read_nifs;
mod runtime;
#[cfg(test)]
mod tests;

use std::future::Future;
use std::panic::{catch_unwind, AssertUnwindSafe};

use dgraph_topology::{TopologyClient, TopologyError};
use rustler::{Encoder, Env, Term};

use crate::abi::{
    CountResult, KeysResult, NifChangeWrite, NifDeviceWrite, NifEdgeWrite, NifHopWrite,
    NifInterfaceWrite, NifPrefixWrite, WriteResult,
};
use crate::runtime::{client_for, require_url, Failure, Pool, CONNECT_DEADLINE};

pub(crate) mod atoms {
    rustler::atoms! { error }
}

/// Validate, then submit one Dgraph operation. Rejections that need no Dgraph
/// round trip come back synchronously as `{:error, reason}`.
pub(crate) fn dgraph_call<'a, T, R, Op, Fut>(
    env: Env<'a>,
    url: String,
    pool: Pool,
    deadline_ms: u64,
    op: Op,
    finish: impl FnOnce(Result<T, String>) -> R + Send + 'static,
) -> Term<'a>
where
    Op: FnOnce(TopologyClient) -> Fut + Send + 'static,
    Fut: Future<Output = Result<T, TopologyError>> + Send + 'static,
    T: Send + 'static,
    R: Encoder,
{
    let submitted = catch_unwind(AssertUnwindSafe(|| {
        if let Err(reason) = require_url(&url) {
            return (atoms::error(), reason).encode(env);
        }
        call::submit(
            env,
            pool,
            deadline_ms,
            move |remaining| async move {
                let client = client_for(&url, CONNECT_DEADLINE.min(remaining)).await?;
                op(client).await.map_err(Failure::from)
            },
            finish,
        )
    }));
    submitted.unwrap_or_else(|_| {
        (
            atoms::error(),
            "dgraph nif panicked (call isolated)".to_string(),
        )
            .encode(env)
    })
}

pub(crate) fn write_call<'a, Op, Fut>(
    env: Env<'a>,
    url: String,
    deadline_ms: u64,
    op: Op,
) -> Term<'a>
where
    Op: FnOnce(TopologyClient) -> Fut + Send + 'static,
    Fut: Future<Output = Result<(), TopologyError>> + Send + 'static,
{
    write_call_in(env, url, Pool::Item, deadline_ms, op)
}

pub(crate) fn write_call_in<'a, Op, Fut>(
    env: Env<'a>,
    url: String,
    pool: Pool,
    deadline_ms: u64,
    op: Op,
) -> Term<'a>
where
    Op: FnOnce(TopologyClient) -> Fut + Send + 'static,
    Fut: Future<Output = Result<(), TopologyError>> + Send + 'static,
{
    dgraph_call(env, url, pool, deadline_ms, op, |result| match result {
        Ok(()) => WriteResult::Ok,
        Err(reason) => WriteResult::Error(reason),
    })
}

pub(crate) fn keys_call<'a, Op, Fut>(
    env: Env<'a>,
    url: String,
    deadline_ms: u64,
    op: Op,
) -> Term<'a>
where
    Op: FnOnce(TopologyClient) -> Fut + Send + 'static,
    Fut: Future<Output = Result<Vec<String>, TopologyError>> + Send + 'static,
{
    dgraph_call(
        env,
        url,
        Pool::Item,
        deadline_ms,
        op,
        |result| match result {
            Ok(keys) => KeysResult::Ok(keys),
            Err(reason) => KeysResult::Error(reason),
        },
    )
}

pub(crate) fn rejected(env: Env<'_>, reason: String) -> Term<'_> {
    (atoms::error(), reason).encode(env)
}

#[rustler::nif]
fn upsert_device(env: Env<'_>, url: String, device: NifDeviceWrite, deadline_ms: u64) -> Term<'_> {
    let write = device.into_write();
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_device(&write).await
    })
}

#[rustler::nif]
fn upsert_interface(
    env: Env<'_>,
    url: String,
    iface: NifInterfaceWrite,
    deadline_ms: u64,
) -> Term<'_> {
    let write = iface.into_write();
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_interface(&write).await
    })
}

#[rustler::nif]
fn upsert_prefix(env: Env<'_>, url: String, prefix: NifPrefixWrite, deadline_ms: u64) -> Term<'_> {
    let write = prefix.into_write();
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_prefix(&write).await
    })
}

#[rustler::nif]
fn attach_prefix(
    env: Env<'_>,
    url: String,
    iface_key: String,
    cidr: String,
    deadline_ms: u64,
) -> Term<'_> {
    write_call(env, url, deadline_ms, move |client| async move {
        client.attach_prefix(&iface_key, &cidr).await
    })
}

#[rustler::nif]
fn upsert_change(env: Env<'_>, url: String, change: NifChangeWrite, deadline_ms: u64) -> Term<'_> {
    let write = change.into_write();
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_change(&write).await
    })
}

#[rustler::nif]
fn upsert_hop(env: Env<'_>, url: String, hop: NifHopWrite, deadline_ms: u64) -> Term<'_> {
    let write = hop.into_write();
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_hop(&write).await
    })
}

#[rustler::nif]
fn upsert_edge(env: Env<'_>, url: String, edge: NifEdgeWrite, deadline_ms: u64) -> Term<'_> {
    let write = edge.into_write();
    if let Err(err) = write.validate_last_seen() {
        return rejected(env, err.to_string());
    }
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_edge(&write).await
    })
}

/// Devices and the interfaces they own, one conditional mutation per device
/// in a single request. Replies with the ids of devices skipped as ambiguous.
#[rustler::nif]
fn upsert_device_graphs(
    env: Env<'_>,
    url: String,
    devices: Vec<NifDeviceWrite>,
    interfaces: Vec<NifInterfaceWrite>,
    deadline_ms: u64,
) -> Term<'_> {
    let devices: Vec<_> = devices
        .into_iter()
        .map(NifDeviceWrite::into_write)
        .collect();
    let interfaces: Vec<_> = interfaces
        .into_iter()
        .map(NifInterfaceWrite::into_write)
        .collect();
    keys_call(env, url, deadline_ms, move |client| async move {
        client.upsert_device_graphs(&devices, &interfaces).await
    })
}

/// Edges in one transaction. Replies with the link keys of edges skipped
/// because an endpoint is missing or ambiguous.
#[rustler::nif]
fn upsert_edges(env: Env<'_>, url: String, edges: Vec<NifEdgeWrite>, deadline_ms: u64) -> Term<'_> {
    let writes: Vec<_> = edges.into_iter().map(NifEdgeWrite::into_write).collect();
    for write in &writes {
        if let Err(err) = write.validate_last_seen() {
            return rejected(env, err.to_string());
        }
    }
    keys_call(env, url, deadline_ms, move |client| async move {
        client.upsert_edges(&writes).await
    })
}

#[rustler::nif]
fn replace_hosted_edge(
    env: Env<'_>,
    url: String,
    edge: NifEdgeWrite,
    deadline_ms: u64,
) -> Term<'_> {
    let write = edge.into_write();
    if let Err(err) = write.validate_hosted_replacement() {
        return rejected(env, err.to_string());
    }
    write_call(env, url, deadline_ms, move |client| async move {
        client.replace_hosted_edge(&write).await
    })
}

#[rustler::nif]
fn retire_hosted_edge(
    env: Env<'_>,
    url: String,
    source: String,
    target: String,
    observed_at: String,
    deadline_ms: u64,
) -> Term<'_> {
    write_call(env, url, deadline_ms, move |client| async move {
        client
            .retire_hosted_edge(&source, &target, &observed_at)
            .await
    })
}

#[rustler::nif]
fn replace_contained_edge(
    env: Env<'_>,
    url: String,
    edge: NifEdgeWrite,
    deadline_ms: u64,
) -> Term<'_> {
    let write = edge.into_write();
    if let Err(err) = write.validate_contained_replacement() {
        return rejected(env, err.to_string());
    }
    write_call(env, url, deadline_ms, move |client| async move {
        client.replace_contained_edge(&write).await
    })
}

#[rustler::nif]
fn retire_contained_edge(
    env: Env<'_>,
    url: String,
    source: String,
    target: String,
    observed_at: String,
    deadline_ms: u64,
) -> Term<'_> {
    write_call(env, url, deadline_ms, move |client| async move {
        client
            .retire_contained_edge(&source, &target, &observed_at)
            .await
    })
}

#[rustler::nif]
fn upsert_canonical_edge(
    env: Env<'_>,
    url: String,
    edge: NifEdgeWrite,
    deadline_ms: u64,
) -> Term<'_> {
    let write = edge.into_write();
    if let Err(err) = write.validate_last_seen() {
        return rejected(env, err.to_string());
    }
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_canonical_edge(&write).await
    })
}

#[rustler::nif]
fn update_canonical_edge_telemetry(
    env: Env<'_>,
    url: String,
    edge: NifEdgeWrite,
    deadline_ms: u64,
) -> Term<'_> {
    let write = edge.into_write();
    write_call(env, url, deadline_ms, move |client| async move {
        client.update_canonical_edge_telemetry(&write).await
    })
}

#[rustler::nif]
fn upsert_mtr_path(env: Env<'_>, url: String, edge: NifEdgeWrite, deadline_ms: u64) -> Term<'_> {
    let write = edge.into_write();
    if let Err(err) = write.validate_last_seen() {
        return rejected(env, err.to_string());
    }
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_mtr_path(&write).await
    })
}

#[rustler::nif]
fn prune_stale(
    env: Env<'_>,
    url: String,
    cutoff: String,
    kinds: Vec<String>,
    deadline_ms: u64,
) -> Term<'_> {
    dgraph_call(
        env,
        url,
        Pool::Bulk,
        deadline_ms,
        move |client| async move { client.prune_stale(&cutoff, &kinds).await },
        |result| match result {
            Ok(count) => CountResult::Ok(count as u64),
            Err(reason) => CountResult::Error(reason),
        },
    )
}

/// One chunk of a canonical rebuild: up to a few hundred edges upserted in
/// one Dgraph transaction. Idempotent, so the Elixir driver may retry it.
#[rustler::nif]
fn upsert_canonical_edges(
    env: Env<'_>,
    url: String,
    edges: Vec<NifEdgeWrite>,
    deadline_ms: u64,
) -> Term<'_> {
    let writes: Vec<_> = edges.into_iter().map(NifEdgeWrite::into_write).collect();
    for write in &writes {
        if let Err(err) = write.validate_last_seen() {
            return rejected(env, err.to_string());
        }
    }
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_canonical_edges(&writes).await
    })
}

/// Link keys of stored canonical edges outside the desired set (a whole-graph
/// read, so it uses the bulk pool).
#[rustler::nif]
fn stale_canonical_keys(
    env: Env<'_>,
    url: String,
    edges: Vec<NifEdgeWrite>,
    deadline_ms: u64,
) -> Term<'_> {
    let writes: Vec<_> = edges.into_iter().map(NifEdgeWrite::into_write).collect();
    dgraph_call(
        env,
        url,
        Pool::Bulk,
        deadline_ms,
        move |client| async move { client.stale_canonical_keys(&writes).await },
        |result| match result {
            Ok(keys) => KeysResult::Ok(keys),
            Err(reason) => KeysResult::Error(reason),
        },
    )
}

/// One chunk of a canonical rebuild's stale deletes, in one transaction.
/// Missing keys are skipped, so a repeat is harmless.
#[rustler::nif]
fn delete_canonical_edges(
    env: Env<'_>,
    url: String,
    link_keys: Vec<String>,
    deadline_ms: u64,
) -> Term<'_> {
    write_call(env, url, deadline_ms, move |client| async move {
        client.delete_canonical_edges(&link_keys).await
    })
}

rustler::init!("Elixir.ServiceRadar.Dgraph.Native");
