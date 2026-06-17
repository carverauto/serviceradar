// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! NIF batch I/O wrappers. The detector input/output types themselves live in
//! `serviceradar-anomaly-core` (re-exported here so `crate::types::*` keeps
//! resolving); only the batch request/response envelopes are NIF-specific.

use rustler::NifMap;

pub(crate) use serviceradar_anomaly_core::types::{
    ReasonContext, ReasonEventVerdict, ReasonSample, ReasonVerdict,
};

#[derive(Clone, Debug, NifMap)]
pub(crate) struct ReasonBatchInput {
    pub(crate) context: ReasonContext,
    pub(crate) sample: ReasonSample,
}

#[derive(Debug, NifMap)]
pub(crate) struct ReasonBatchResult {
    pub(crate) ok: Option<ReasonVerdict>,
    pub(crate) error: Option<String>,
}

#[derive(Debug, NifMap)]
pub(crate) struct ReasonEventBatchResult {
    pub(crate) ok: Option<ReasonEventVerdict>,
    pub(crate) error: Option<String>,
}
