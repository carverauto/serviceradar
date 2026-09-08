//! Integration test entry point.
//!
//! The tests/ tree mirrors src/ exactly; each module is registered here so that a test file
//! cannot be added without also being wired in. Everything is exercised through the crate's
//! public API, as a consumer sees it.

#[cfg(test)]
mod errors;
#[cfg(test)]
mod types;
