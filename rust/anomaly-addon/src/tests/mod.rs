// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Crate-internal test suite. These tests exercise private functions, so they
//! live inside the crate (not the integration `tests/` dir). Split per concern.

mod support;

mod checkpoint;
mod classify;
mod config;
mod counter;
mod demo_metric_corpus;
mod demo_metric_corpus_data;
mod engine;
mod frame;
mod health;
mod identity;
mod seasonal;
mod shed;
mod stream;
mod verdict;
