# Change: Give mapper discovery its own SNMP credential

## Why

The SNMP credential a mapper discovery job falls back on comes from whichever SNMP
polling profile has `is_default = true` (or, before that, the agent host's polling
credential or the first agent-scoped SNMP monitoring rule, whatever its target
query). The fallback covers the addresses discovery exists to find: seeds and
LLDP/CDP neighbours that have no device record yet.
`MapperCompiler.resolve_default_credentials/2` calls
`CredentialResolver.resolve_default/2`. When nothing resolves, it logs a warning and
compiles the job with a bare `{"version" => "v2c"}`. The mapper then speaks SNMPv2c
with an empty community.

In a recent incident the default flag was cleared on a deployment's only default
profile. Every SNMP discovery job then compiled without credentials until the flag
was restored, and the only signal was thousands of repeated compiler warnings.
Nothing in the discovery UI showed that the jobs could no longer authenticate.
A polling profile's flag should not silently decide whether discovery can log in.

## What Changes

- **A mapper job names its own SNMP discovery credential.** `MapperJob` gains
  `snmp_credential_secret_id`, a direct, restrict-on-delete reference to a reusable
  SNMP credential in `platform.network_credential_secrets`. It follows the
  established pattern of the job's UniFi and MikroTik controllers. The job's own
  record (agent/partition assignment, seeds) defines the scope. This is the typed
  consumer case the credential hard rule allows, and the change carries the four
  obligations that rule attaches to a new direct reference: product approval, a
  restrictive FK, credential-usage inventory plus guarded deletion, and a navigable
  usage surface.
- **Per-device resolution is unchanged.** A device the inventory knows still
  resolves through the shared order: device override, matching SNMP monitoring
  rule, targeting profile, default profile. The result goes into the job's
  `target_specific` credentials. The job credential covers every other address.
- **The implicit fallback chain is removed.** The mapper compile no longer
  resolves the agent host's polling credential, an unscoped agent/partition SNMP
  monitoring rule, or the default profile as a job fallback.
  `CredentialResolver.resolve_default/2`, whose only caller is the mapper, is
  deleted. The default profile's `is_default` flag no longer affects discovery.
- **A missing credential is operator-visible and fails closed.** An SNMP or
  SNMP+API job without a credential compiles with an empty base credential `{}`.
  The mapper already treats `{}` as "do not speak SNMP to this address", and the
  compiler already emits it for suppressed targets. **BREAKING (wire):** the
  compiler stops emitting `{"version" => "v2c"}` with no community. The job is
  flagged in the Discovery job list and form as missing its SNMP credential.
  Credential reads that fail for other reasons keep failing the compile, as they
  do today.
- **One-time migration, no secret re-entry.** A backfill decides each job that
  existed before the upgrade exactly once, tracked by a per-job mark.
  For every such SNMP-mode job it replays the pre-change fallback chain and binds the
  job to the credential that chain resolves today. Inline legacy material on a
  profile or device override is promoted to a reusable credential, and the source
  record is rebound to it, so one secret serves both consumers.
- **Pin the profile edit contract.** Saving the SNMP profile edit form never
  changes `is_default`. Code reading shows the `:update` action does not accept the
  attribute. The implementation adds a regression test that fails if the form ever
  starts clearing it. The only writers that clear the flag are the explicit
  "Clear default" action and "Set as default" on another profile.

## Impact

- Affected specs: `network-discovery`, `snmp-checker`
- Pending delta touched: `enable-snmpv3-poller-discovery` (its
  `Discovery credential resolution via profiles` copy described an agent-scoped
  rule acting as the job fallback; its scenario is reworded to the per-device
  semantics this change keeps)
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_job.ex`
    (attribute, relationship, FK, accept lists) plus a migration
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/mapper_compiler.ex`
    (per-job base credential, remove fallback chain)
  - `elixir/serviceradar_core/lib/serviceradar/snmp_profiles/credential_resolver.ex`
    (delete `resolve_default/2`)
  - `elixir/serviceradar_core/lib/serviceradar/credentials/credential_usage.ex`,
    `network_credential_secret.ex` (`foreign_key_names`)
  - New one-shot backfill worker under `network_discovery/`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/**`
    (credential select, missing-credential badge) and the credential usage
    surface (mapper job link)
- Out of scope: the SNMP poller's unbound-host fallback
  (`CredentialResolver.resolve_for_host/3` → `resolve_unbound_host/2`) still uses
  the first agent-scoped monitoring rule for hosts with no device record. That is
  polling, not discovery, and is left for a separate change.
