//! Integration test entry point.
//!
//! The tests/ tree mirrors src/ exactly; each module is registered here so a test file cannot be
//! added without being wired in, and everything is exercised through the public API.

#[cfg(test)]
mod errors;
#[cfg(test)]
mod traits;
#[cfg(test)]
mod types;
