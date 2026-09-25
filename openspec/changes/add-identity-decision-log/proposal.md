# Change: Record every DIRE identity decision in a persisted decision log

## Why

DIRE decides not to merge in several places: `MergePolicy` refuses a match set, a
`MergeEngine` guard refuses an automatic merge, `AliasGuard` stales an IP alias that
conflicts with another device's identity, and the sync device write keeps a strong-identified
record off an address a different device holds. Only the source-authority block and the
active-IP conflict left a row (in `source_identity_conflicts`, the Armis drift table); the
rest reached telemetry and a log line only. An operator cannot review, count or act on a
decision nobody can query, which violates "Identity Decisions Are Never Silent"
(`update-dire-strong-identity-goal`, #4613). The formal model carries the gap as the
`silent_blocks` switch.

## What Changes

- New resource `ServiceRadar.Inventory.IdentityDecision` (`platform.identity_decisions`):
  one row per distinct decision -- kind, reason, sorted device set, subject address -- with
  the latest evidence, an occurrence count and first/last decision times. Readable by any
  viewer; written only by a system actor.
- `ServiceRadar.Inventory.Identity.DecisionLog` writes it next to the existing telemetry at
  every decision site: `MergePolicy.record_blocked_merge/4` (all three policy callers),
  `MergeEngine.merge_devices/3` guard refusals, `SourceAuthorityGuard.record_blocked/3` (all
  three source-authority callers), `AliasGuard.invalidate_ip_alias/5` (both alias paths), and
  the sync device write's active-IP conflicts.
- The `source_override` kind exists for the source-authoritative override that the
  `src_attach_via_mac` fix introduces; that fix records it through the same API.
- The DIRE resolution model drops the `silent_blocks` switch and its witness; each trace's
  `recorded` set is now read from `identity_decisions` rows, so trace validation checks that
  the code actually wrote what it decided.

## Impact

- Affected specs: `device-identity-reconciliation` (ADDED "Persisted Identity Decision Log").
- Affected code: `elixir/serviceradar_core` identity modules, one migration, the DIRE trace
  harness and `formal/dire`.
- The Armis `source_identity_conflicts` rows are still written; they drive the northbound
  workflow and drift reports and are not replaced.
- Operator review and resolution of these decisions is the de-duplication task work (#4604).
