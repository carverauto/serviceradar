## Context

`MapperCompiler.compile/3` builds one `credentials` map per agent and gives it to
every scheduled job:

- `base`: `resolve_credentials(device_uid)`. This resolves the agent host's own
  device through the shared polling order (device override, matching SNMP
  monitoring rule, targeting profile, default profile). When that yields nothing it
  calls `CredentialResolver.resolve_default/2`, which takes the first enabled SNMP
  monitoring rule scoped to the agent or partition, ignoring its target query. If no
  such rule exists it takes the credential of the profile with `is_default = true`.
  If that is empty too, the job gets `{"version" => "v2c"}`.
- `target_specific`: for every known device among the seeds and every device a
  scoped monitoring rule matches, the same shared order. `:suppressed` addresses
  encode as `{}`, which the Go mapper refuses
  (`configureClientVersion` returns `ErrUnsupportedSNMPVersion`).

The mapper uses `target_specific[ip]` when present and `base` otherwise. Every
neighbour that LLDP, CDP or ARP/FDB reveals and that inventory does not know yet,
which is the point of discovery, therefore authenticates with `base`. `base` is
decided by data that has nothing to do with discovery: the agent host's polling
assignment, a monitoring rule's position in priority order, or a polling profile's
default flag.

## Goals / Non-Goals

- Goals: the fallback credential is chosen explicitly per job, visible on the job,
  and unaffected by polling-profile edits. A job without one fails closed and says
  so. Existing deployments keep discovering after upgrade without re-entering
  secrets.
- Non-Goals: changing per-device resolution for known devices; changing SNMP
  polling (including the poller's unbound-host rule fallback); multiple fallback
  credentials per job (try-list); changing how the mapper reports per-target walk
  failures.

## Decisions

### Decision 1: a direct, typed reference on `MapperJob`, not a discovery-purpose rule

`MapperJob.snmp_credential_secret_id` (nullable UUID) references
`platform.network_credential_secrets` with `on_delete: :restrict`.

Why this and not a credential rule with purpose `snmp_discovery`:

- **The fallback is not selected per target.** Rules exist to choose credentials
  dynamically per target through an SRQL target query. The fallback covers exactly
  the addresses that have no device record, so a target query has nothing to
  evaluate. Today's `resolve_unscoped_rule_credential/2` ignores the target query
  for that reason, which is how a rule written for `in:devices hostname:host01`
  ends up as the fallback for every unknown address on the agent. A
  discovery-purpose rule would either repeat that flaw or need a new address/CIDR
  targeting model to mean anything.
- **The scope is the job's own record.** A job is assigned to an agent or a
  partition and carries its own seeds. The native SNMP descriptor allows only
  `agent` scope for rules, so a partition-assigned job could not be expressed
  without widening the descriptor. Two jobs on one agent (two sites, two
  communities) cannot get different fallbacks from an agent-scoped rule. A job
  reference handles both cases with no new mechanism.
- **Precedent in the same aggregate.** `MapperUnifiController` and
  `MapperMikrotikController`, children of the same job, already reference
  `credential_secret_id` directly, with restrict FKs, entries in
  `CredentialUsage.load_direct_consumers/1` and `foreign_key_names` on
  `NetworkCredentialSecret`. The operator picks the job's API credentials and its
  SNMP credential on the same form.
- **Visibility.** The question "what will this job log in with?" is answered on the
  job, not by reconstructing rule priority order.

The credential hard rule attaches four obligations to a new direct reference.
They are met as follows:

1. *Approved product contract*: this proposal, approved by the product owner on
   2026-11-15 (task 0.1).
2. *Restrictive FK*: `on_delete: :restrict`, plus a `foreign_key_names` entry
   mapping `mapper_jobs_snmp_credential_secret_id_fkey` to `credential_in_use`.
3. *Usage inventory and guarded deletion*: a `:mapper_jobs` loader in
   `CredentialUsage.load_direct_consumers/1` (consumer kind `:mapper_job`, labelled
   by job name), so the existing guarded-deletion checks count it and fail closed
   when the loader fails.
4. *Navigable usage surface*: the credential usage list renders a mapper-job
   consumer as a link to that job's edit form under Settings → Networks →
   Discovery.

Only SNMP credentials (`credential_kind == :snmp`) are accepted. The job form's
select reuses the SNMP-credential options the profile form already uses. The
`:create`/`:update` actions validate that a referenced secret is an SNMP
credential.

Brokered resolution is audited with consumer `mapper_job:<id>`, target kind
`mapper_job` and purpose `mapper_discovery`, the purpose the job's UniFi and
MikroTik controller credentials already use. A compile that serves several jobs
sharing one secret audits it once per job consumer through the existing
`with_bulk_audit/2` grouping.

### Decision 2: per-job base credential; implicit chain deleted

The compile resolves `target_specific` once per agent, as today, and the base
credential once per distinct referenced secret, then builds each job's
`credentials` from its own base plus the shared `target_specific`. The
`device_uid` host resolution and `resolve_default/2` leave the mapper path.
`resolve_default/2` has no other caller and is deleted. Per-device resolution is
untouched, so a known device the default profile polls is still discovered with
that profile's credential. That is the polling credential for that device, and it
stops applying when the device stops being polled, which is consistent.

### Decision 3: missing credential fails closed and shows on the job

- Compile: an SNMP-mode job (`:snmp` or `:snmp_api`) with a nil reference gets base
  `{}`. The mapper refuses SNMP for every address without a `target_specific` entry
  and still uses per-device credentials for known devices. The API half of an
  `:snmp_api` job is unaffected. The compiler does not log once per compile per
  job: the state lives on the record, not in logs.
- A referenced credential that cannot be built (deterministic broker refusal,
  unknown security level) also yields `{}` for that job and logs once per compile.
  A credential **read** failure fails the compile, as it does today, because
  caching a config that contradicts the data is worse.
- UI: the Discovery jobs list shows a warning badge, "No SNMP credential", on every
  SNMP-mode job with a nil reference, with a title explaining that only devices
  with their own credential will be probed. The job form shows the same warning
  inline under the credential select. Saving such a job is allowed, because
  disabling or retargeting it must not be blocked, but the warning persists until a
  credential is chosen.
- An `:api` job never needs the reference, and the badge never shows for it.

### Decision 4: one-time backfill replays the old chain

The Ecto migration only adds the nullable column and FK. A one-shot Oban worker,
`MapperJobSNMPCredentialBackfillWorker`, enqueued on core start and unique per
deployment, does the binding, because it needs SRQL rule matching and, for inline
material, decryption:

1. For each SNMP-mode job with a nil reference, enabled or disabled (the worker
   reads jobs directly, not through `for_agent_partition`, which returns only
   enabled jobs), and for each agent the job compiles for, evaluate the
   **pre-change** fallback chain: host device resolution from that agent row's
   `device_uid`, then `resolve_default`. The agent set comes from persisted
   `Agent` rows, never from the in-memory `AgentRegistry`, which is empty until
   gateways sync after boot: an agent-assigned job uses its assigned agent's row;
   a partition-assigned job, enabled or disabled, uses every `Agent` row whose
   metadata `partition_id` (default `"default"`) equals the job's partition, the
   same rule `AgentAssignment` validates. A missing assigned agent row, an empty
   partition agent set, or a failure to load either is a retryable failure under
   step 4, not an agreed empty chain; the job stays unbound and keeps showing the
   Decision 3 warning until a retry binds it. The worker carries a private copy of that legacy logic,
   deleted along with the worker in a later release.
2. If every agent resolves to the same credential, bind the job to it. Agreement
   is judged by credential, not by the record it came from: a source with a
   reusable secret (`credential_secret_id` on a profile or override, `secret_id`
   on a rule) is compared by that secret id, so the same secret reached through
   different records on different agents still agrees; inline legacy material,
   which has no secret id yet, is compared by its source record.
   - the agreed credential is a reusable secret: bind that id.
   - the agreed credential is inline legacy material on a profile or device override: promote it
     to a reusable SNMP credential (same builder as the profile form's "Save as
     reusable"), rebind the source record to the new secret, and bind the job,
     all in one transaction. Decryption of the inline material is audited with
     purpose `mapper_discovery_backfill`. A failure rolls back all three, so no
     orphan secret is left for a retry to duplicate. A source that already has a
     reusable secret id, including one rebound earlier in the same run for
     another job sharing it, is bound to that id and never promoted again. There
     is still one copy, so rotation stays single-source.
3. If agents disagree, or the chain agrees on no credential, leave the job unbound. It then shows
   the Decision 3 warning, the honest state, since no single credential reproduces
   the old behaviour.
4. Record completion in a deployment-level marker only after every job has been
   bound or deliberately left unbound under step 3. A credential read failure, a
   missing or unloadable agent set (step 1), or a failed promote, rebind or bind
   transaction is not an empty result: the run aborts without the marker and Oban
   retries it. Binding touches only nil references and step 2 binds an already
   rebound source by its secret id, so a retry neither rebinds a bound job nor
   promotes the same material twice. Once the marker exists the worker never runs again, so it never
   rebinds a job an operator later cleared on purpose.

Binding a job updates the record, and `DependencyNotifier` recompiles the
affected agents.

### Decision 5: the profile edit path is not the bug, and gets a contract test

`SNMPProfile.:update` accepts `@profile_fields`, which excludes `is_default`, and
the web-ng edit form submits through `Form.for_update(:update)`. Saving the edit
form therefore cannot clear the flag. The flag is cleared only by `:unset_default`
(the "Clear default" button, behind a confirm dialog) and by `SetAsDefault`, which
demotes the previous default through an unaudited `Repo.update_all` when another
profile is starred. `snmp_profiles` has no paper trail, so which writer acted
during the incident cannot be recovered from the data. The implementation adds a
web-ng regression test: editing a default profile's target query and saving keeps
`is_default = true`. Once discovery no longer reads the flag, a cleared flag
affects only polling, where the "Clear default" confirm text already describes the
consequence.

## Alternatives considered

- **`snmp_discovery` credential rule scoped by agent/partition and target query.**
  Rejected for the reasons in Decision 1: no target to match, no partition scope
  for SNMP rules, one fallback per agent, and it keeps the "first rule wins"
  ordering problem.
- **Keep the chain and only alert when it resolves nothing.** Rejected: it leaves
  discovery's ability to log in decided by polling configuration, which is the
  coupling at fault.
- **Require a credential when saving an SNMP-mode job.** Rejected for now. Jobs
  the backfill could not bind must stay editable (disable, change mode), and a
  persistent warning already covers visibility. This can be revisited once no
  unbound jobs remain.
- **A compatibility shim that keeps the old chain until the backfill finishes.**
  Rejected: see Risks for the bounded window this leaves.

## Risks / Trade-offs

- **Startup window.** A mapper config compiled after the upgrade and before the
  backfill binds jobs has base `{}`. The backfill runs seconds after boot, and
  binding triggers a recompile. Discovery runs on job intervals, so at most a run
  that fires inside that window probes only known devices once.
- **Behaviour change for rule-fallback deployments.** A deployment whose fallback
  came from an agent-scoped monitoring rule is migrated to that rule's secret. A
  rule added later for monitoring no longer changes discovery's fallback, which is
  the intended effect but must be stated in the CHANGELOG.
- **Partition jobs with divergent agents** end up unbound and visible rather than
  guessed.

## Migration Plan

1. Ecto migration: add `mapper_jobs.snmp_credential_secret_id uuid NULL
   REFERENCES platform.network_credential_secrets(id) ON DELETE RESTRICT` plus an
   index.
2. Deploy. The backfill binds jobs. Verify with
   `SELECT id, name FROM platform.mapper_jobs WHERE discovery_mode IN ('snmp','snmp_api') AND snmp_credential_secret_id IS NULL`,
   which should list only jobs that legitimately had no fallback.
3. Rollback: the column is nullable and ignored by older code, so a rollback to the
   previous release restores the old chain. A credential promoted from inline
   material stays reusable, and the rebound profile/override keeps working on old
   code because it resolves `credential_secret_id` first.

## Resolved Questions

- Product approval of the new direct credential reference on `MapperJob`, as the
  credential hard rule requires: approved by the product owner on 2026-11-15.
- Removing the agent-scoped monitoring-rule fallback for unknown addresses as a
  default behaviour change, with the backfill preserving each existing
  deployment's resolved credential: approved by the product owner on 2026-11-15.
