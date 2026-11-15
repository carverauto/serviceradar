## 0. Approval

- [ ] 0.1 Product approval of the direct `MapperJob.snmp_credential_secret_id`
      reference (credential hard rule) and of dropping the implicit fallback chain

## 1. Data model

- [ ] 1.1 Migration: nullable `mapper_jobs.snmp_credential_secret_id` FK to
      `network_credential_secrets` with `ON DELETE RESTRICT`, plus index
- [ ] 1.2 `MapperJob`: attribute, `belongs_to :snmp_credential_secret`,
      `references ... on_delete: :restrict`, accept on `:create`/`:update`,
      validation that the referenced secret's provider is `snmp`
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
      purpose `snmp_discovery`); remove `resolve_credentials/3` host-device
      fallback and `resolve_default_credentials/2`; no per-compile warning for
      unbound jobs
- [ ] 2.3 Delete `CredentialResolver.resolve_default/2` and update the module doc
- [ ] 2.4 Add `MapperJob` to the compiler's dependency set if not already
      recompiled on its credential change (DependencyNotifier)

## 3. Migration

- [ ] 3.1 Fail-first tests for the backfill: reusable default-profile secret bound;
      inline profile material promoted and source rebound; agent-scoped rule secret
      bound; divergent partition agents left unbound; completion marker prevents a
      second run
- [ ] 3.2 `MapperJobSNMPCredentialBackfillWorker`: one-shot, unique, enqueued on
      core start, private copy of the legacy chain, deployment-level completion
      marker
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
