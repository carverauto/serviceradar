# Reuse content-bound exposure publication validation

Status: proposed; implementation and hosted execution are not approved.

## Why

PR #6176 confirmed that sharing source scans and dimension lookups did not
close the exposure reconciliation capacity gap. The synthetic audit took
about 34 seconds versus 31 previously. Its fact interval was about 16.5
seconds against a 6-second screen. One diagnostic cohort spent about 3.1 of
5.1 seconds in typed projection, including about 2.2 seconds of per-row
validation. These are inclusive plan timings, not a CPU profile.

The retained after-image normally does not change between audits. Rechecking
its full JSON structure, timestamps and typed values on every audit repeats
work. Current assessment values and actual warehouse content still need
independent checks every time.

## What Changes

- Propose a disabled scratch prototype of content-bound validation receipts:
  retain a validity verdict, the existing replay digest and dimension reference
  ordinals, rather than another copy of the fact or normalized JSON tuple.
- Bind each receipt to the full retained payload's database-maintained
  fingerprint and a versioned validator/digest contract. Missing or stale
  receipts cannot produce a successful comparison.
- Continue hashing current assessment columns and actual warehouse columns
  independently. Preserve existing dimension proofs, recovery, readiness and
  sequence rules.
- Measure preparation, source write overhead, storage and recovery costs as
  well as audit latency. No result from a prepared fixture alone can establish
  fleet readiness.

This explicitly changes the preceding prototype's prohibition on persistent
retained-publication validation. Approval would authorize only a disabled
prototype and ordinary remote validation through no-mistakes. A hosted
measurement allocation, production migration and adoption each remain separate.

## Impact

- Capability: exposure-intelligence; parent task 1.6 remains open.
- Prototype surface: existing manual exposure audit harness and scratch schema.
- Potential adoption surface, not implemented here: assessment fingerprint,
  Ash-backed validation control metadata, bounded preparation, migration and
  restore hooks.
- No exposure query fallback in CNPG; no new exposure fact projection, payload
  copy, repair executor, writer to StarRocks, or codec change.
- Prior results: [shared-scan report](../refactor-exposure-cohort-source-scan/design.md#one-authorized-measurement)
  and [audit protocol](../refactor-exposure-reconciliation-audit/design.md).
