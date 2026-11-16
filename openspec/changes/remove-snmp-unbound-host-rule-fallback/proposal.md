# Change: Stop SNMP credential rules leaking onto explicit targets with no device

## Why

An explicit SNMP target (an `SNMPTarget` row on a profile) is polled with the
credential `SNMPCompiler.profile_target_credential/3` resolves for its host.
When the host belongs to a device, `CredentialResolver.resolve_for_host/3`
resolves that device: a monitoring rule applies only when its target query
selects the device. When the host belongs to no device, it called
`resolve_unbound_host/2`, which took the first enabled SNMP monitoring rule
scoped to the compiling agent or its partition, in priority order, and ignored
the rule's target query. That rule also beat the target's own credential.

A rule written for one device (`in:devices hostname:host01.example.com`)
therefore became the polling credential of every explicit target on the agent
whose host has no device record. Adding or reordering an unrelated rule
silently changed which credential those targets were polled with, and nothing
told the operator which rule had been chosen or why (#6633).

Mapper discovery had the same fallback and lost it in
`decouple-mapper-discovery-credential`, whose design gives the reason that
applies here too: rules choose credentials per target through an SRQL target
query over devices, and an address no device holds gives that query nothing to
select.

## What Changes

- **A rule applies to an explicit target only through its target query.** A
  host that belongs to no device resolves to no rule credential, whatever the
  rule's scope or priority. `resolve_unbound_host/2` and
  `resolve_unscoped_rule_credential/2` are deleted. Hosts that belong to a
  device are unchanged.
- **Such a target is polled with its own credential.** The target's
  referenced reusable credential, else its inline material, as already
  happens when no rule applies.
- **A target without a usable credential is reported.** The compiler emits
  `[:serviceradar, :snmp, :target_without_credential]` on every compile that
  skips one and logs a warning when the condition starts, as it does for a
  profile whose templates name no OID. The settings list of legacy manual
  targets marks a target that names no credential of its own.
- **One-time backfill, no secret re-entry.** A migration enqueues
  `SNMPTargetCredentialBackfillWorker` once. For every explicit target that has
  no credential of its own and whose host belongs to no device, it replays the
  old fallback for every registered agent compiling the target's profile. When
  they all chose a rule with the same reusable credential, and the target bound
  to that credential resolves to exactly what the rule delivered, the target is
  bound to it. A target with a credential of its own is not changed: it is
  now polled with what was configured for it, not with the borrowed rule.

## Impact

- Affected specs: `snmp-checker`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/credential_resolver.ex`
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/snmp_compiler.ex`
  - New `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/snmp_target_credential_backfill_worker.ex`
    and the migration that enqueues it
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/snmp_profiles_live/index/view/profile_form.ex`
- Behaviour change on upgrade: an explicit target on a host with no device
  record that has its own credential switches from the borrowed rule's
  credential to its own.
- Out of scope: explicit targets on hosts that belong to a device still take a
  matching rule before their own credential and still ignore the device's
  override; query-selected device targets are unchanged.
