//! Integration test entry point.
//!
//! Every module is registered here so that a test file cannot be added without also being wired
//! in, and everything is exercised through the crate's public API as a consumer sees it.
//!
//! Most of these read artifacts that protoc compiles during the build -- the rule set, the
//! fixtures, each committed instance, the schema descriptor. Those are BUILD OUTPUTS, and this
//! repository removes Bazel's convenience symlinks, so `cargo test` has no path to them. Rather
//! than let cargo silently cover less, they carry `#[ignore]` with the reason: cargo lists them
//! as ignored, and the Bazel target passes `--include-ignored` so the authoritative build runs
//! the whole suite.

#[cfg(test)]
mod credential_shape_tests;
#[cfg(test)]
mod file_phase_tests;
#[cfg(test)]
mod meta_rule_tests;
#[cfg(test)]
mod predicate_law_tests;
#[cfg(test)]
mod round_trip_tests;
#[cfg(test)]
mod vector_tests;

// section_privilege_tests is deliberately NOT registered here. It asserts that a target
// declaring one config section cannot see the others, so it must be its own target with exactly
// one data dependency; folding it in beside every other fixture would hand it the whole set and
// destroy the property it exists to prove.
