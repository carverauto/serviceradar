# Proposal: fix Default SNMP profile preview, seed, and legacy targets

## Problem

Demo's "Default SNMP" profile targets `in:devices` (10,001 devices for one
agent; the per-agent limit is 10,000), so every compile refuses it with
"selects more than 10000 targets". The operator cannot narrow it safely:

1. **The settings preview returns "Unknown targets" for narrowed queries.**
   `Targeting.count_target_devices/2` (web-ng) reimplements SRQL filter
   evaluation with its own device/interface field maps and op clauses.
   Anything outside that subset -- `tags.*` filters (the spec's own
   `tags.role:core` example), `in:` lists, `os`, `status`, boolean controls
   -- falls through to `:unknown` (or, for lists, a silent `0`). The
   compiler (`SNMPCompiler.reduce_target_pages/4` via
   `SRQLDeviceMatcher.apply_filters/3`) accepts all of these, so the preview
   disagrees with the compile it is supposed to predict. This violates
   "SNMP profile target counts use SRQL evaluation" in
   `openspec/specs/snmp-checker/spec.md`.
2. **The fresh-install default is undecided.** The seed migration writes
   `target_query = 'in:devices'`, which is correct at install time (zero
   devices) but exceeds any per-agent limit once the fleet grows past it.
   No narrower static query expresses "poll everything not otherwise
   targeted" without silently unpolling devices.
3. **28 legacy manual targets.** Demo's profile carries 28 `snmp_targets`
   rows with inline Cloak-encrypted `community_encrypted` and
   `credential_secret_id = NULL`. They resolve through the supported
   `build_legacy_credential` path, but there is no per-target
   promote-to-reusable flow (only profiles have "save as reusable"), so an
   operator cannot move them into the unified credential model without
   re-typing secrets.

## What this changes

1. The preview counts through the compiler's own page reducer
   (`SNMPCompiler.reduce_target_pages/4`), deleting the web-ng
   reimplementation (~200 lines of field/op tables). Preview counts equal
   compile counts by construction: anything the compiler accepts, the
   preview counts; unparseable or invalid queries count nothing (as the
   compiler does); only a failed read stays "Unknown".
2. The fresh-install seed stays `target_query = 'in:devices'`, recorded as
   a spec requirement. Rationale: the default profile's purpose is to catch
   everything no targeting profile claims; any static narrowing silently
   unpolls devices, which is worse than a loud limit refusal. Growth past
   the per-agent limit is handled by the existing guardrails -- save-time
   refusal (`CheckTargetLimit`), compile-time refusal (`TargetLimit.check`
   with `report_target_limit_refusal`), and the now-working preview plus
   split-across-agents guidance in the refusal message.
3. The 28 legacy inline-credential targets are NOT migrated automatically.
   The inline path is a supported credential path (encrypted at rest,
   decrypted only at compile, per "SNMP Credential Security"), and the
   credential model keeps direct-bound credentials working without
   re-entry. An automatic migration would invent rule scopes the operator
   never approved and duplicate secrets. Recorded as a spec requirement;
   per-target promotion UI is future work, not this change.

## Impact

- Affected spec: `snmp-checker` (one MODIFIED requirement with new
  scenarios, two ADDED requirements).
- Affected code: `elixir/web-ng/.../snmp_profiles_live/index/targeting.ex`
  (delete reimplementation, delegate to core), no migration, no seed change.
- Demo: no hand edits. The operator narrows the profile in the UI once
  this ships; the fixed preview shows the count before saving.
