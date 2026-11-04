/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! Scratch-namespace lifecycle for callers outside Rust tests.
//!
//! The Elixir core integration lanes cannot allocate Dgraph namespaces
//! through the topology NIF, so `ServiceRadar.TestSupport.DgraphScratch`
//! drives this binary instead. It shares `support/fixture.rs` with the Rust
//! live tests, so namespace ownership, TLS verification and cleanup
//! verification have exactly one implementation.
//!
//! Usage:
//!   dgraph_scratch_cli create
//!       Allocates a namespace, applies the topology schema, verifies it is
//!       complete, and prints `namespace=`, `url=` and `ca_path=` lines. On
//!       any failure after allocation the namespace is dropped first.
//!   dgraph_scratch_cli drop <namespace>
//!       Drops the namespace and verifies it is gone.
//!
//! Configuration is the typed CI fixture (`SERVICERADAR_ENV=ci`, the
//! `ci.binpb` runfile, and the `DGRAPH_ADMIN_PASSWORD` secret), identical to
//! `schema_lifecycle_test`. CI only; there is no other environment.

use std::time::Duration;

use dgraph_migrate::{Mode, Outcome, run_with_client, verify};
use dgraph_topology::schema_spec;

#[path = "fixture.rs"]
mod fixture;
use fixture::{create_scratch_namespace, drop_scratch_namespace, scratch_client};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [command] if command == "create" => create().await,
        [command, namespace] if command == "drop" => drop(namespace).await,
        _ => Err("usage: dgraph_scratch_cli create | drop <namespace>".to_owned()),
    };
    if let Err(error) = result {
        eprintln!("dgraph_scratch_cli: {error}");
        std::process::exit(1);
    }
}

async fn create() -> Result<(), String> {
    let scratch = tokio::time::timeout(Duration::from_secs(120), create_scratch_namespace())
        .await
        .map_err(|_| "scratch namespace allocation timed out".to_owned())??;
    if let Err(error) = apply_schema(&scratch.url).await {
        // Never leak a namespace whose schema could not be applied.
        let _ = drop_scratch_namespace(scratch.namespace).await;
        let _ = std::fs::remove_file(&scratch.ca_path);
        return Err(error);
    }
    println!("namespace={}", scratch.namespace);
    println!("url={}", scratch.url);
    println!(
        "ca_path={}",
        scratch.ca_path.to_str().expect("CA path is UTF-8")
    );
    Ok(())
}

async fn apply_schema(url: &str) -> Result<(), String> {
    let client = scratch_client(url).await?;
    let spec = schema_spec();
    let outcome = tokio::time::timeout(
        Duration::from_secs(120),
        run_with_client(&client, spec, Mode::Migrate),
    )
    .await
    .map_err(|_| "topology schema migration timed out".to_owned())?
    .map_err(|error| format!("apply topology schema: {error}"))?;
    match outcome {
        Outcome::Migrated(_) | Outcome::AlreadyCurrent => {}
        other => return Err(format!("unexpected migration outcome: {other:?}")),
    }
    let report = tokio::time::timeout(Duration::from_secs(30), verify(&client, spec))
        .await
        .map_err(|_| "topology schema verification timed out".to_owned())?
        .map_err(|error| format!("verify topology schema: {error}"))?;
    if !report.is_complete() {
        return Err("topology schema incomplete after migration".to_owned());
    }
    Ok(())
}

async fn drop(namespace: &str) -> Result<(), String> {
    let namespace: u64 = namespace
        .parse()
        .map_err(|_| format!("invalid namespace id: {namespace}"))?;
    tokio::time::timeout(Duration::from_secs(120), drop_scratch_namespace(namespace))
        .await
        .map_err(|_| "scratch namespace drop timed out".to_owned())?
}
