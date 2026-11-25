// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

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
