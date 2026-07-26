/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

mod setup;
mod start;
mod stop;

mod build;
mod check_running;
mod dbg;
mod default;
mod prune;
mod pull;
mod utils;

#[derive(Debug, Copy, Clone, Ord, PartialOrd, Eq, PartialEq)]
pub struct DockerUtil {
    dbg: bool,
}
