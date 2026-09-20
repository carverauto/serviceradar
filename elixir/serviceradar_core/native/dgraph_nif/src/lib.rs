// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Thin Rustler ABI over `dgraph_topology`. Typed `NifMap` writes, read-only
//! DQL escape hatch, dedicated tokio runtime, DirtyIo, `catch_unwind` per call.

mod abi;
mod runtime;

use std::future::Future;
use std::panic::{catch_unwind, AssertUnwindSafe};

use dgraph_topology::TopologyClient;

use crate::abi::{
    refuses_mutation, CanonicalEdgesResult, CountResult, JsonResult, NeighbourhoodResult,
    NifCanonicalEdge, NifChangeWrite, NifDeviceWrite, NifEdgeWrite, NifHopWrite, NifInterfaceWrite,
    NifNeighbourhoodEdge, NifPrefixWrite, WriteResult,
};
use crate::runtime::{client_for, require_url, runtime};

fn isolate<T, F>(f: F) -> Result<T, String>
where
    F: FnOnce() -> Result<T, String>,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result,
        Err(_) => Err("dgraph nif panicked (call isolated)".to_string()),
    }
}

fn write_call<Fut>(url: String, f: impl FnOnce(TopologyClient) -> Fut) -> WriteResult
where
    Fut: Future<Output = Result<(), dgraph_topology::TopologyError>>,
{
    match isolate(|| {
        require_url(&url)?;
        let client = client_for(&url)?;
        runtime()?
            .block_on(f(client))
            .map_err(|err| err.to_string())
    }) {
        Ok(()) => WriteResult::Ok,
        Err(reason) => WriteResult::Error(reason),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn upsert_device(url: String, device: NifDeviceWrite) -> WriteResult {
    let write = device.into_write();
    write_call(url, move |client| async move {
        client.upsert_device(&write).await
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn upsert_interface(url: String, iface: NifInterfaceWrite) -> WriteResult {
    let write = iface.into_write();
    write_call(url, move |client| async move {
        client.upsert_interface(&write).await
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn upsert_prefix(url: String, prefix: NifPrefixWrite) -> WriteResult {
    let write = prefix.into_write();
    write_call(url, move |client| async move {
        client.upsert_prefix(&write).await
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn attach_prefix(url: String, iface_key: String, cidr: String) -> WriteResult {
    write_call(url, move |client| async move {
        client.attach_prefix(&iface_key, &cidr).await
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn upsert_change(url: String, change: NifChangeWrite) -> WriteResult {
    let write = change.into_write();
    write_call(url, move |client| async move {
        client.upsert_change(&write).await
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn upsert_hop(url: String, hop: NifHopWrite) -> WriteResult {
    let write = hop.into_write();
    write_call(
        url,
        move |client| async move { client.upsert_hop(&write).await },
    )
}

#[rustler::nif(schedule = "DirtyIo")]
fn upsert_edge(url: String, edge: NifEdgeWrite) -> WriteResult {
    let write = edge.into_write();
    write_call(url, move |client| async move {
        client.upsert_edge(&write).await
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn upsert_canonical_edge(url: String, edge: NifEdgeWrite) -> WriteResult {
    let write = edge.into_write();
    write_call(url, move |client| async move {
        client.upsert_canonical_edge(&write).await
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn upsert_mtr_path(url: String, edge: NifEdgeWrite) -> WriteResult {
    let write = edge.into_write();
    write_call(url, move |client| async move {
        client.upsert_mtr_path(&write).await
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn prune_stale(url: String, cutoff: String, kinds: Vec<String>) -> CountResult {
    match isolate(|| {
        require_url(&url)?;
        let client = client_for(&url)?;
        runtime()?
            .block_on(client.prune_stale(&cutoff, &kinds))
            .map_err(|err| err.to_string())
    }) {
        Ok(count) => CountResult::Ok(count as u64),
        Err(reason) => CountResult::Error(reason),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn rebuild_canonical(url: String, edges: Vec<NifEdgeWrite>) -> WriteResult {
    let writes: Vec<_> = edges.into_iter().map(NifEdgeWrite::into_write).collect();
    write_call(url, move |client| async move {
        client.rebuild_canonical(&writes).await
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn query_canonical_edges(url: String) -> CanonicalEdgesResult {
    match isolate(|| {
        require_url(&url)?;
        let client = client_for(&url)?;
        let edges = runtime()?
            .block_on(client.query_canonical_edges())
            .map_err(|err| err.to_string())?;
        Ok(edges.iter().map(NifCanonicalEdge::from).collect())
    }) {
        Ok(edges) => CanonicalEdgesResult::Ok(edges),
        Err(reason) => CanonicalEdgesResult::Error(reason),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn query_neighbourhood(url: String, device_id: String) -> NeighbourhoodResult {
    match isolate(|| {
        require_url(&url)?;
        let client = client_for(&url)?;
        let edges = runtime()?
            .block_on(client.query_neighbourhood(&device_id))
            .map_err(|err| err.to_string())?;
        Ok(edges.iter().map(NifNeighbourhoodEdge::from).collect())
    }) {
        Ok(edges) => NeighbourhoodResult::Ok(edges),
        Err(reason) => NeighbourhoodResult::Error(reason),
    }
}

/// Read-only DQL. Mutations are refused here and again in the Elixir facade.
#[rustler::nif(schedule = "DirtyIo")]
fn query_dql(url: String, dql: String) -> JsonResult {
    query_dql_impl(url, dql)
}

fn query_dql_impl(url: String, dql: String) -> JsonResult {
    if refuses_mutation(&dql) {
        return JsonResult::Error("dql escape hatch refuses mutations".to_string());
    }
    match isolate(|| {
        require_url(&url)?;
        let client = client_for(&url)?;
        let value = runtime()?
            .block_on(client.query_dql(&dql))
            .map_err(|err| err.to_string())?;
        serde_json::to_string(&value).map_err(|err| err.to_string())
    }) {
        Ok(json) => JsonResult::Ok(json),
        Err(reason) => JsonResult::Error(reason),
    }
}

rustler::init!("Elixir.ServiceRadar.Dgraph.Native");

#[cfg(test)]
mod tests {
    use super::*;
    use crate::abi::refuses_mutation;

    #[test]
    fn query_dql_refuses_mutations_without_connecting() {
        let result = query_dql_impl(
            "dgraph://unused:9080".to_string(),
            "mutation { set { _:x <dgraph.type> \"Device\" } }".to_string(),
        );
        match result {
            JsonResult::Error(reason) => {
                assert!(
                    reason.contains("refuses mutations"),
                    "expected mutation refusal, got {reason}"
                )
            }
            JsonResult::Ok(json) => panic!("mutation must not query, got {json}"),
        }
    }

    #[test]
    fn empty_url_is_an_error_atom_not_a_panic() {
        let result = query_dql_impl(String::new(), "{ q(func: uid(0x1)) { uid } }".to_string());
        match result {
            JsonResult::Error(reason) => assert!(reason.contains("not configured")),
            JsonResult::Ok(json) => panic!("empty url must error, got {json}"),
        }
    }

    #[test]
    fn panic_is_isolated_to_the_call() {
        let net = catch_unwind(AssertUnwindSafe(|| -> WriteResult {
            #[allow(clippy::panic)]
            {
                panic!("simulated dgraph nif panic")
            }
        }));
        assert!(net.is_err(), "premise: the closure panics");

        let isolated = isolate(|| -> Result<(), String> {
            #[allow(clippy::panic)]
            {
                panic!("simulated dgraph nif panic")
            }
        });
        match isolated {
            Err(reason) => assert!(reason.contains("panicked")),
            Ok(()) => panic!("catch_unwind must surface as error"),
        }
    }

    #[test]
    fn read_query_is_not_a_mutation() {
        assert!(!refuses_mutation(
            "{ edges(func: type(TopologyEdge)) { topo.link_key } }"
        ));
    }
}
