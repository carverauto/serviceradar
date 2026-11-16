# Change: Resolve explicit SNMP target credentials in the documented order

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

The first PR of this change left a second defect, on hosts that DO belong to a
device. `SNMPCompiler.profile_target_credential/3` kept a credential from
`resolve_for_host/3` only when its source was `:credential_rule`, and
otherwise used the target's own credential. A device's SNMP override, which
the resolver ranks above every rule, was therefore ignored on an explicit
target, and so was the profile's credential: a target with no credential of
its own and no matching rule was not polled although its profile carried one.
The documented order, and the one query-selected device targets and Mapper
follow, is device override, then a rule whose target query selects the device,
then profile credentials.

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
- **One precedence for every explicit target.** An explicit target is
  resolved by `CredentialResolver.resolve_for_target/4`, which runs the
  same pipeline as query-selected and Mapper devices (`resolve_for_devices/3`):
  the device override, then a rule whose scope covers the agent and whose
  target query selects the device, then the target's own credential, then the
  credential of the profile the target belongs to. A host no device holds
  skips the first two. `resolve_for_host/3` is deleted, and the compiler no
  longer picks a source out of the resolver's answer.
- **A matching rule still outranks the target's own credential**, as it did
  before this change, so no target that resolved to a rule moves to its own
  credential. A credential meant for one device ahead of every rule is that
  device's SNMP override, which now applies to explicit targets too.
- **A refused override, rule or target credential skips the target**, as it
  does for a query-selected device, instead of falling through to a
  lower-precedence credential.
- **A manual target that resolves a credential replaces a query-selected
  target for the same host**, including when the credential is inherited from
  its profile, so that host is polled only with the manual target's OIDs.
- **No backfill for the follow-up.** Only targets whose device has an override
  change credential, to the one the operator configured for that device;
  targets that had no credential and no rule start polling with their
  profile's. No working target loses its credential.

## Impact

- Affected specs: `snmp-checker`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/credential_resolver.ex`
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/snmp_compiler.ex`
  - `docs/docs/credentials.md`
  - New `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/snmp_target_credential_backfill_worker.ex`
    and the migration that enqueues it
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/snmp_profiles_live/index/view/profile_form.ex`
- Behaviour change on upgrade: an explicit target on a host with no device
  record that has its own credential switches from the borrowed rule's
  credential to its own.
- Behaviour change in the follow-up: an explicit target whose device has an
  SNMP override is polled with the override; an explicit target with no
  credential of its own and no override or rule is polled with its profile's
  credential instead of not at all. Query-selected device targets and Mapper
  are unchanged.
