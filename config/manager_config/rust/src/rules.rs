//! The committed rule set, embedded in the binary.
//!
//! It is NOT a parameter. The rule set does not vary by environment, by component or by
//! deployment -- it is one committed artifact that every implementation reads. Taking it as an
//! argument said otherwise, and that claim is what dragged it into the dependency graph of every
//! call site: a service had to obtain the rules before it could obtain its configuration, and
//! the only mechanism available was runfiles, which a container does not have.
//!
//! # Why embedded rather than mounted beside the instance
//!
//! Deliberate, and the whole value of the check rests on it. The instance is read from a mount
//! at runtime -- untrusted, and the thing being verified. Reading the rules from that same mount
//! would let whatever supplied a bad instance supply the rules that bless it, which proves
//! nothing. Embedding puts the rules on the trusted side of the boundary: they are fixed when
//! the binary is built, and a swapped ConfigMap cannot weaken them.
//!
//! # Why a committed artifact
//!
//! `include_bytes!` needs the file to exist for `cargo` as well as Bazel, and the .binpb is
//! protoc output. The tree already commits generated bindings under a drift guard, and this
//! follows that pattern: `//config/manager_config/rust:ruleset_drift_test` diffs this copy
//! against what protoc produces from `//config/rules:ruleset.textproto`, so the two cannot
//! disagree.

use serviceradar_config_schema::RuleSet;
use std::sync::OnceLock;

/// protoc output for `//config/rules/ruleset.textproto`, byte-for-byte.
const RULESET: &[u8] = include_bytes!("ruleset.binpb");

/// The rule set every load validates against.
///
/// Decoded once. A panic here is correct rather than an error to propagate: the bytes are a
/// build input of this very binary, so a decode failure means the artifact that shipped is
/// broken, not that the caller did anything wrong.
pub fn embedded() -> &'static RuleSet {
    static RULES: OnceLock<RuleSet> = OnceLock::new();
    RULES.get_or_init(|| {
        <RuleSet as prost::Message>::decode(RULESET)
            .expect("the embedded rule set failed to decode; the built artifact is broken")
    })
}

/// The instances `Source::BuiltIn` refers to, compiled into the release.
///
/// `localhost` and `ci` resolve to `Source::BuiltIn`, whose whole meaning is "compiled into the
/// release" -- so a binary that cannot produce them cannot run in those environments at all. That
/// is not a test concern: it is why `rust/srql` could not use ConfigManager. Every consumer would
/// otherwise have to obtain the same two committed artifacts, and the only mechanism available to
/// a container was runfiles, which it does not have.
///
/// The MOUNTED kinds are deliberately absent. Those genuinely vary per deployment, which is the
/// entire reason they are mounted rather than built in, and embedding them would let a release
/// disagree with the platform about what `demo` means.
///
/// Guarded by `//config/manager_config/rust:instance_drift_{localhost,ci}_test`.
pub fn built_ins() -> crate::types::config_manager::BuiltIns<'static> {
    const LOCALHOST: &[u8] = include_bytes!("localhost.binpb");
    const CI: &[u8] = include_bytes!("ci.binpb");
    &[("localhost", LOCALHOST), ("ci", CI)]
}
