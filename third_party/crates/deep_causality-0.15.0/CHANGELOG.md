# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **[BREAKING]** *(deep_causality)* Adapted to the `deep_causality_core` carrier change: the
  `PropagatingEffect` / `PropagatingProcess` value-XOR-error channel is now a single private
  `outcome: Result<EffectValue<Value>, Error>` (the W-invariant, enforced by construction). Read
  sites move from the `.value` / `.error` fields to the getters `value() -> Option<&Value>` (carried
  scalar), `effect() -> Option<&EffectValue<Value>>` (wrapper, for `RelayTo` / `None` discrimination),
  `error() -> Option<&Error>`, plus `value_cloned()` / `into_value()` for owned access; construction
  moves from struct literals to `::new(Ok(..)/Err(..), state, context, logs)` and the named
  constructors. Effect evaluation, graph/collection reasoning, and CSM behavior are unchanged.

## [0.8.1](https://github.com/marvin-hansen/deep_causality/compare/deep_causality-v0.8.0...deep_causality-v0.8.1) - 2025-07-10

### Other

- Fixed memory leak in ultragraph bench ([#261](https://github.com/marvin-hansen/deep_causality/pull/261))
