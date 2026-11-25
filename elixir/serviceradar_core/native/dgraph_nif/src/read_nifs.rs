// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use dgraph_topology::{wrap_dql_value, DownstreamFact};
use rustler::{Env, Term};

use crate::abi::{
    refuses_mutation, CanonicalEdgesResult, CanonicalGraphResult, DownstreamResult, JsonResult,
    MtrPathsResult, NeighbourhoodResult, NifCanonicalEdge, NifCanonicalGraph, NifDownstreamFact,
    NifMtrPath, NifNeighbourhoodEdge,
};
use crate::runtime::Pool;
use crate::{dgraph_call, rejected};

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
fn query_rebuild_inputs(env: Env<'_>, url: String, deadline_ms: u64) -> Term<'_> {
    dgraph_call(
        env,
        url,
        Pool::Bulk,
        deadline_ms,
        |client| async move { client.query_rebuild_inputs().await },
        |result| match result
            .and_then(|rows| serde_json::to_string(&rows).map_err(|err| err.to_string()))
        {
            Ok(json) => JsonResult::Ok(json),
            Err(reason) => JsonResult::Error(reason),
        },
    )
}

#[rustler::nif]
fn query_interfaces_by_key(
    env: Env<'_>,
    url: String,
    keys: Vec<String>,
    deadline_ms: u64,
) -> Term<'_> {
    dgraph_call(
        env,
        url,
        Pool::Bulk,
        deadline_ms,
        move |client| async move { client.query_interfaces_by_key(&keys).await },
        |result| match result
            .and_then(|rows| serde_json::to_string(&rows).map_err(|err| err.to_string()))
        {
            Ok(json) => JsonResult::Ok(json),
            Err(reason) => JsonResult::Error(reason),
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

#[rustler::nif]
fn query_mtr_paths(env: Env<'_>, url: String, limit: u64, deadline_ms: u64) -> Term<'_> {
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    dgraph_call(
        env,
        url,
        Pool::Item,
        deadline_ms,
        move |client| async move { client.query_mtr_paths(limit).await },
        |result| match result {
            Ok(paths) => MtrPathsResult::Ok(paths.iter().map(NifMtrPath::from).collect()),
            Err(reason) => MtrPathsResult::Error(reason),
        },
    )
}

#[rustler::nif]
fn query_device_neighborhood(
    env: Env<'_>,
    url: String,
    device_id: String,
    include_topology: bool,
    deadline_ms: u64,
) -> Term<'_> {
    dgraph_call(
        env,
        url,
        Pool::Item,
        deadline_ms,
        move |client| async move {
            client
                .query_device_neighborhood(&device_id, include_topology)
                .await
        },
        |result| match result
            .and_then(|value| serde_json::to_string(&value).map_err(|err| err.to_string()))
        {
            Ok(json) => JsonResult::Ok(json),
            Err(reason) => JsonResult::Error(reason),
        },
    )
}

#[rustler::nif]
fn query_graph_dql(env: Env<'_>, url: String, dql: String, deadline_ms: u64) -> Term<'_> {
    if refuses_mutation(&dql) {
        return rejected(env, "dql escape hatch refuses mutations".to_string());
    }
    dgraph_call(
        env,
        url,
        Pool::Item,
        deadline_ms,
        move |client| async move { client.query_dql(&dql).await.map(wrap_dql_value) },
        |result| match result
            .and_then(|rows| serde_json::to_string(&rows).map_err(|err| err.to_string()))
        {
            Ok(json) => JsonResult::Ok(json),
            Err(reason) => JsonResult::Error(reason),
        },
    )
}

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
