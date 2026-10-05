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
mod runtime;

use std::future::Future;
use std::panic::{catch_unwind, AssertUnwindSafe};

use dgraph_topology::{DownstreamFact, TopologyClient, TopologyError};
use rustler::{Encoder, Env, Term};

use crate::abi::{
    refuses_mutation, CanonicalEdgesResult, CanonicalGraphResult, CountResult, DownstreamResult,
    JsonResult, KeysResult, NeighbourhoodResult, NifCanonicalEdge, NifCanonicalGraph,
    NifChangeWrite, NifDeviceWrite, NifDownstreamFact, NifEdgeWrite, NifHopWrite,
    NifInterfaceWrite, NifNeighbourhoodEdge, NifPrefixWrite, WriteResult,
};
use crate::runtime::{client_for, require_url, Failure, Pool, CONNECT_DEADLINE};

mod atoms {
    rustler::atoms! { error }
}

/// Validate, then submit one Dgraph operation. Rejections that need no Dgraph
/// round trip come back synchronously as `{:error, reason}`.
fn dgraph_call<'a, T, R, Op, Fut>(
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

fn write_call<'a, Op, Fut>(env: Env<'a>, url: String, deadline_ms: u64, op: Op) -> Term<'a>
where
    Op: FnOnce(TopologyClient) -> Fut + Send + 'static,
    Fut: Future<Output = Result<(), TopologyError>> + Send + 'static,
{
    write_call_in(env, url, Pool::Item, deadline_ms, op)
}

fn write_call_in<'a, Op, Fut>(
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

fn rejected(env: Env<'_>, reason: String) -> Term<'_> {
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
    write_call(env, url, deadline_ms, move |client| async move {
        client.upsert_edge(&write).await
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
fn upsert_canonical_edge(
    env: Env<'_>,
    url: String,
    edge: NifEdgeWrite,
    deadline_ms: u64,
) -> Term<'_> {
    let write = edge.into_write();
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

#[rustler::nif]
fn downstream_of(
    env: Env<'_>,
    url: String,
    from_ids: Vec<String>,
    to_ids: Vec<String>,
    deadline_ms: u64,
) -> Term<'_> {
    dgraph_call(
        env,
        url,
        Pool::Item,
        deadline_ms,
        move |client| async move { client.downstream_of(&from_ids, &to_ids).await },
        |result| match result {
            Ok(DownstreamFact::Reachable) => DownstreamResult::Ok(NifDownstreamFact::Reachable),
            Ok(DownstreamFact::Disjoint) => DownstreamResult::Ok(NifDownstreamFact::Disjoint),
            Err(reason) => DownstreamResult::Error(reason),
        },
    )
}

#[rustler::nif]
fn query_canonical_edges(env: Env<'_>, url: String, deadline_ms: u64) -> Term<'_> {
    dgraph_call(
        env,
        url,
        Pool::Bulk,
        deadline_ms,
        |client| async move { client.query_canonical_edges().await },
        |result| match result {
            Ok(edges) => {
                CanonicalEdgesResult::Ok(edges.iter().map(NifCanonicalEdge::from).collect())
            }
            Err(reason) => CanonicalEdgesResult::Error(reason),
        },
    )
}

#[rustler::nif]
fn query_canonical_graph(env: Env<'_>, url: String, deadline_ms: u64) -> Term<'_> {
    dgraph_call(
        env,
        url,
        Pool::Bulk,
        deadline_ms,
        |client| async move { client.query_canonical_graph().await },
        |result| match result {
            Ok(graph) => CanonicalGraphResult::Ok(NifCanonicalGraph::from(&graph)),
            Err(reason) => CanonicalGraphResult::Error(reason),
        },
    )
}

#[rustler::nif]
fn query_neighbourhood(env: Env<'_>, url: String, device_id: String, deadline_ms: u64) -> Term<'_> {
    dgraph_call(
        env,
        url,
        Pool::Item,
        deadline_ms,
        move |client| async move { client.query_neighbourhood(&device_id).await },
        |result| match result {
            Ok(edges) => {
                NeighbourhoodResult::Ok(edges.iter().map(NifNeighbourhoodEdge::from).collect())
            }
            Err(reason) => NeighbourhoodResult::Error(reason),
        },
    )
}

/// Read-only DQL. Mutations are refused here and again in the Elixir facade.
#[rustler::nif]
fn query_dql(env: Env<'_>, url: String, dql: String, deadline_ms: u64) -> Term<'_> {
    if refuses_mutation(&dql) {
        return rejected(env, "dql escape hatch refuses mutations".to_string());
    }
    dgraph_call(
        env,
        url,
        Pool::Item,
        deadline_ms,
        move |client| async move { client.query_dql(&dql).await },
        |result| match result
            .and_then(|value| serde_json::to_string(&value).map_err(|err| err.to_string()))
        {
            Ok(json) => JsonResult::Ok(json),
            Err(reason) => JsonResult::Error(reason),
        },
    )
}

rustler::init!("Elixir.ServiceRadar.Dgraph.Native");

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use tokio::sync::Semaphore;

    use crate::abi::refuses_mutation;
    use crate::call::{execute, Kind};
    use crate::runtime::{client_for, Failure};

    /// A listener that completes the TCP handshake from its backlog but never
    /// accepts or answers: the shape of a black-holed or wedged Dgraph.
    fn black_hole() -> (std::net::TcpListener, String) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let port = listener.local_addr().expect("local addr").port();
        (listener, format!("dgraph://127.0.0.1:{port}"))
    }

    fn block_on<F: std::future::Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .expect("test runtime")
            .block_on(future)
    }

    #[test]
    fn connecting_to_a_black_hole_times_out_within_the_connect_bound() {
        let (_listener, url) = black_hole();
        let started = Instant::now();
        let result = block_on(client_for(&url, Duration::from_millis(300)));
        assert!(
            matches!(&result, Err(Failure::Timeout(reason)) if reason.contains("connect timed out")),
            "expected a connect timeout, got {:?}",
            result.map(|_| ())
        );
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_black_holed_call_reports_a_timeout() {
        let (_listener, url) = black_hole();
        let report = block_on(execute(
            Arc::new(Semaphore::new(1)),
            Duration::from_millis(300),
            move |remaining| async move {
                let client = client_for(&url, remaining).await?;
                client
                    .query_dql("{ q(func: uid(0x1)) { uid } }")
                    .await
                    .map_err(Failure::from)
            },
        ));
        assert_eq!(report.kind, Kind::Timeout);
        assert!(report.elapsed < Duration::from_secs(5));
    }

    #[test]
    fn an_unreachable_cluster_is_transient() {
        // Bind then close: nothing listens on the port, so connect is refused.
        let port = {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind loopback");
            listener.local_addr().expect("local addr").port()
        };
        let result = block_on(client_for(
            &format!("dgraph://127.0.0.1:{port}"),
            Duration::from_secs(5),
        ));
        assert!(
            matches!(result, Err(Failure::Transient(_))),
            "a refused connection must be retryable, got {:?}",
            result.map(|_| ())
        );
    }

    #[test]
    fn read_query_is_not_a_mutation() {
        assert!(!refuses_mutation(
            "{ edges(func: type(TopologyEdge)) { topo.link_key } }"
        ));
        assert!(refuses_mutation(
            "mutation { set { _:x <dgraph.type> \"Device\" } }"
        ));
    }
}
