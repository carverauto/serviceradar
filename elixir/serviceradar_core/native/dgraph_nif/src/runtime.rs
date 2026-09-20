// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Process-wide tokio runtime and TopologyClient cache. Dgraph RPCs never
//! run on a BEAM scheduler thread; DirtyIo NIFs `block_on` here.

use std::sync::{Mutex, OnceLock};

use dgraph_topology::TopologyClient;
use tokio::runtime::Runtime;

struct CachedClient {
    url: String,
    client: TopologyClient,
}

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static CLIENT: OnceLock<Mutex<Option<CachedClient>>> = OnceLock::new();

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

/// Cached client for `url`, reconnecting when the URL changes.
///
/// # Errors
///
/// Returns a string when the URL is empty, the cache is poisoned, or connect fails.
pub fn client_for(url: &str) -> Result<TopologyClient, String> {
    require_url(url)?;
    let cache = CLIENT.get_or_init(|| Mutex::new(None));
    {
        let guard = cache
            .lock()
            .map_err(|_| "dgraph client cache poisoned".to_string())?;
        if let Some(cached) = guard.as_ref() {
            if cached.url == url {
                return Ok(cached.client.clone());
            }
        }
    }

    let client = runtime()?
        .block_on(TopologyClient::connect(url))
        .map_err(|err| err.to_string())?;
    let mut guard = cache
        .lock()
        .map_err(|_| "dgraph client cache poisoned".to_string())?;
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
