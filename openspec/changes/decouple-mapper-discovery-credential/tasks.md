## 0. Approval

- [x] 0.1 Product approval of the direct `MapperJob.snmp_credential_secret_id`
      reference (credential hard rule) and of dropping the implicit fallback chain,
      including agent-scoped monitoring rules as the discovery fallback (approved
      by the product owner on 2026-11-15)

## 1. Data model

- [ ] 1.1 Migration: nullable `mapper_jobs.snmp_credential_secret_id` FK to
      `network_credential_secrets` with `ON DELETE RESTRICT`, plus index; and
      `mapper_jobs.snmp_credential_backfill_pending boolean NOT NULL DEFAULT true`
      then `SET DEFAULT false` (catalog-only, no `UPDATE`), written only by the
      system-only `MapperJob` action `:complete_snmp_credential_backfill`
- [ ] 1.2 `MapperJob`: attribute, `belongs_to :snmp_credential_secret`,
      `references ... on_delete: :restrict`, accept on `:create`/`:update`,
      validation that the referenced secret's `credential_kind` is `:snmp`
- [ ] 1.3 `NetworkCredentialSecret.foreign_key_names`: map
      `mapper_jobs_snmp_credential_secret_id_fkey` to `credential_in_use`
- [ ] 1.4 `CredentialUsage.load_direct_consumers/1`: `:mapper_jobs` loader
      (consumer kind `:mapper_job`, label = job name)

## 2. Compiler

- [ ] 2.1 Fail-first tests in `mapper_compiler_test.exs`: job credential is the
      base; clearing `is_default` leaves base unchanged; an unmatched agent-scoped
      monitoring rule is not the base; two jobs on one agent get their own bases;
      no reference gives base `{}` (never `{"version" => "v2c"}`); read failure
      fails the compile; `:api` job unaffected
- [ ] 2.2 `MapperCompiler`: per-job base credential from the job reference
      (resolved once per distinct secret, audit consumer `mapper_job:<id>`,
      purpose `mapper_discovery`); remove `resolve_credentials/3` host-device
      fallback and `resolve_default_credentials/2`; no per-compile warning for
      unbound jobs
- [ ] 2.3 Delete `CredentialResolver.resolve_default/2` and update the module doc
- [ ] 2.4 Add `MapperJob` to the compiler's dependency set if not already
      recompiled on its credential change (DependencyNotifier)

## 3. Migration

- [ ] 3.1 Fail-first tests for the backfill: reusable default-profile secret bound;
      inline profile material promoted and source rebound; agent-scoped rule secret
      bound; disabled job bound; disabled partition job evaluated against the
      partition's persisted, non-superseded agents (by `partition_id`, with no
      agent connected); superseded agent's rule ignored; each agent evaluated with
      its own uid, the job partition and its `device_uid`; partition agents
      reaching the same secret id through different records bound; divergent
      partition agents left unbound and unmarked; inline promotion failure rolls
      back secret, rebind and bind together; two jobs sharing an inline source get
      one promoted secret; a missing agent row, empty partition agent set, or read
      or write failure leaves only that job marked, decides the others, and fails
      the run; a retry does not rebind a decided job an operator cleared; a job
      created after the migration is never marked or bound; a job that already references a
      credential has its mark cleared without its secret changing; a job changed
      between read and decision stays marked and the run fails
- [ ] 3.2 `MapperJobSNMPCredentialBackfillWorker`: one-shot, unique, enqueued on
      core start, private copy of the legacy chain, visits only marked jobs
      (including disabled ones), agent set from persisted non-superseded `Agent`
      rows, promote/rebind/bind in one transaction (audit purpose
      `mapper_discovery_backfill`), each decision written by
      `:complete_snmp_credential_backfill` (sets the secret when binding, clears
      the mark; filter: mark set AND secret id equals the value read; zero rows
      leaves the job marked and fails the run)
- [ ] 3.2a Add `:complete_snmp_credential_backfill` to the `DependencyCatalog`
      `mapper_job_config` `action_names`, with a test that a committed bind
      invalidates mapper config
- [ ] 3.2b Optional SNMP `version` (`v1`/`v2c`) on the native community
      credential descriptor and in `ReusableCredential`; the backfill stores `v1`
      when it promotes or copies a v1 community, rebinds sources with the
      system-only `:bind_reusable_credential` action (no target-limit or SRQL
      re-check), and suffixes a taken credential name; tests: inline v1 promoted
      and compiled as v1, versionless v1 secret copied with v1, versionless job
      credential compiles v2c, taken name suffixed, rebind refused for non-system
      actors
- [ ] 3.2c Rotation keeps a community credential's stored version when the
      submission leaves it blank (descriptor `keep_on_rotation`, payload read
      server-side and audited only in that case); an explicit version wins; the
      rotate form labels the blank choice "Keep current version"; the backfill
      reports `no_legacy_credential` only when every agent resolves nothing, and
      `agents_disagree` for a mix
- [ ] 3.3 CHANGELOG: discovery fallback is now the job's credential; the
      default-profile flag and unmatched monitoring rules no longer affect it

## 4. Web-NG

- [ ] 4.1 Discovery job form: SNMP credential select (SNMP credentials only,
      shown for `snmp`/`snmp_api`), inline warning when empty
- [ ] 4.2 Discovery job list: "No SNMP credential" warning badge for SNMP-mode
      jobs without a reference
- [ ] 4.3 Credential usage surface: mapper-job consumer links to the job edit form
- [ ] 4.4 Regression test: editing a default SNMP profile's target query through
      the edit form and saving keeps `is_default = true`
- [ ] 4.5 LiveView tests for 4.1-4.3

## 5. Pending spec alignment

- [x] 5.1 Reword the `enable-snmpv3-poller-discovery` delta's SNMPv3 rule scenario
      to per-device semantics, so archiving it does not reinstate an agent-scoped
      rule as the job fallback

## 6. Validation

- [ ] 6.1 `openspec validate decouple-mapper-discovery-credential --strict`
- [ ] 6.2 Core and web-ng DB tests (srql-fixtures scratch DB), Core Integration in CI
- [ ] 6.3 Demo: after rollout, query unbound SNMP-mode jobs (design Migration Plan
      step 2), clear the default profile flag, confirm the next compile still
      carries the job credential and that no "no default SNMP credentials" warning
      appears
