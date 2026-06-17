// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! `serviceradar-anomaly-addon` binary entrypoint. Serves the add-on over the
//! go-plugin transport exactly like the reference Rust sample add-on.

use addon_sdk::serve;
use serviceradar_anomaly_addon::AnomalyAddon;

#[tokio::main]
async fn main() {
    env_logger::init();

    if let Err(err) = serve(AnomalyAddon::new()).await {
        // Match the Go SDK / go-plugin UX: a direct run (no magic cookie) prints
        // the friendly "this is a plugin" message; otherwise report and exit 1.
        if matches!(err, addon_sdk::ServeError::Handshake(_)) {
            eprint!("{}", addon_sdk::handshake::DIRECT_EXECUTION_MESSAGE);
        } else {
            eprintln!("serviceradar-anomaly-addon: {err}");
        }
        std::process::exit(1);
    }
}
