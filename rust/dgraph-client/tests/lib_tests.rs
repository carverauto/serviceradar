/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Integration test entry point.
//!
//! The tests/ tree mirrors src/ exactly; each module is registered here so that a test
//! file cannot be added without also being wired in.

#[cfg(test)]
mod errors;
#[cfg(test)]
mod types;
