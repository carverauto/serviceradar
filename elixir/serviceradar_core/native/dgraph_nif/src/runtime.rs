// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Process-wide tokio runtime, in-flight call limit and TopologyClient cache.
//!
//! Dgraph RPCs never run on a BEAM scheduler thread. Each NIF spawns its call
//! onto this runtime and returns at once; the call replies by message. The
//! upstream client builds its tonic `Endpoint` with no connect or request
//! timeout and exposes no hook to set one, so every call is bounded by a
//! deadline in `call`, and connecting by `CONNECT_DEADLINE` here.

use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use dgraph_topology::{TopologyClient, TopologyError};
use tokio::runtime::Runtime;
use tokio::sync::Semaphore;

/// Dialing and probing a cluster that has no cached client yet. Also bounded by
/// the remaining call deadline.
pub const CONNECT_DEADLINE: Duration = Duration::from_secs(10);

/// Dgraph calls in flight at once. Excess calls wait for a permit as cheap
/// futures, and that wait counts against their deadline: this is backpressure
/// on Dgraph, not a refusal.
pub const MAX_IN_FLIGHT: usize = 8;

struct CachedClient {
    url: String,
    client: TopologyClient,
}

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static CLIENT: OnceLock<Mutex<Option<CachedClient>>> = OnceLock::new();
static IN_FLIGHT: OnceLock<Arc<Semaphore>> = OnceLock::new();

/// Dedicated multi-thread runtime for Dgraph RPCs.
///
/// # Errors
///
/// Returns a string when the runtime cannot be built.
pub fn runtime() -> Result<&'static Runtime, String> {
    if let Some(runtime) = RUNTIME.get() {
        return Ok(runtime);
    }

    let built = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .thread_name("dgraph-nif")
        .build()
        .map_err(|err| format!("tokio runtime: {err}"))?;

    match RUNTIME.set(built) {
        Ok(()) | Err(_) => RUNTIME
            .get()
            .ok_or_else(|| "tokio runtime missing after init".to_string()),
    }
}

/// The process-wide in-flight limit.
pub fn in_flight() -> Arc<Semaphore> {
    IN_FLIGHT
        .get_or_init(|| Arc::new(Semaphore::new(MAX_IN_FLIGHT)))
        .clone()
}

/// Cached client for `url`, reconnecting when the URL changes.
///
/// # Errors
///
/// Returns a [`TopologyError`] when the cache is poisoned or connect fails, and
/// a `Timeout` failure when connecting outlasts `deadline`.
pub async fn client_for(url: &str, deadline: Duration) -> Result<TopologyClient, Failure> {
    let cache = CLIENT.get_or_init(|| Mutex::new(None));
    {
        let guard = cache
            .lock()
            .map_err(|_| Failure::Error("dgraph client cache poisoned".to_string()))?;
        if let Some(cached) = guard.as_ref() {
            if cached.url == url {
                return Ok(cached.client.clone());
            }
        }
    }

    let client = match tokio::time::timeout(deadline, TopologyClient::connect(url)).await {
        Ok(Ok(client)) => client,
        Ok(Err(err)) => return Err(Failure::from(err)),
        Err(_elapsed) => {
            return Err(Failure::Timeout(format!(
                "dgraph connect timed out after {}ms",
                deadline.as_millis()
            )))
        }
    };
    let mut guard = cache
        .lock()
        .map_err(|_| Failure::Error("dgraph client cache poisoned".to_string()))?;
    *guard = Some(CachedClient {
        url: url.to_string(),
        client: client.clone(),
    });
    Ok(client)
}

/// Reject an empty connection string before dialing.
///
/// # Errors
///
/// Returns a string when `url` is empty or whitespace.
pub fn require_url(url: &str) -> Result<(), String> {
    if url.trim().is_empty() {
        Err("dgraph url is not configured".to_string())
    } else {
        Ok(())
    }
}

/// Why one attempt of a Dgraph call failed, as the Elixir retry policy needs to
/// see it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Failure {
    /// The deadline passed (connect, queue wait, or the RPCs themselves).
    Timeout(String),
    /// A fresh attempt may succeed: unreachable cluster, transport failure,
    /// aborted transaction.
    Transient(String),
    /// Anything else. Retrying cannot help.
    Error(String),
}

impl From<TopologyError> for Failure {
    fn from(err: TopologyError) -> Self {
        if err.is_transient() {
            Self::Transient(err.to_string())
        } else {
            Self::Error(err.to_string())
        }
    }
}
