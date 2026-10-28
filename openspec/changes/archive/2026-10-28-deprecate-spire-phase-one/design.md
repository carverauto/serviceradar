## Context

The issue's three phases separate deprecation from runtime rejection and artifact deletion. Current code still shares legacy configuration between SPIRE and mTLS workloads:

- `helm/serviceradar/templates/core.yaml` reads `spire.coreServiceAccount` and `spire.trustDomain`; its `DATASVC_SEC_MODE` defaults to `spiffe` when `kv.secMode` is blank.
- `helm/serviceradar/templates/_helpers.tpl` derives internal identities and namespace/socket settings from legacy values. Workload templates and SPIRE ClusterSPIFFEIDs must agree on service account identity during compatibility.
- `helm/serviceradar/templates/cnpg-cluster.yaml` suppresses the ordinary cluster when `spire.enabled && spire.postgres.enabled`; `spire-postgres.yaml` renders the alternate cluster. Both affect shared database jobs and credential lookup.
- `helm/serviceradar/values.yaml` already contains a complete `cnpg.*` configuration and default values, as well as `spire.postgres.*`. A naive merge can make shipped defaults overwrite an operator's legacy cluster settings.
- `elixir/serviceradar_core/lib/serviceradar/edge/onboarding_package.ex` currently defaults `security_mode` to `:spire` and accepts both `:spire` and `:mtls`.

## Goals / Non-Goals

Goals are visible deprecation, consistent mTLS defaults for new packages, neutral chart overrides, and a documented migration that preserves deployment state. Phase one must keep explicit SPIRE inputs working.

Runtime/provider deletion, unknown-mode parser changes, rejection of explicit SPIRE package creation, proto reservation/regeneration, dependency removal, CRD deletion and certificate identity renaming belong to later phases. No deployment, database cleanup or certificate rotation is performed by this PR.

## Decisions

1. **Neutral service account resolution.** Add optional blank `serviceAccounts` entries for existing workload components (`core`, `webNg`, `datasvc`, `agent`, `logCollector`, `rperfChecker`, `trapd`, `flowCollector`, `bmpCollector`). Resolve non-blank neutral value, then legacy component account, then existing built-in default. Use the same result in Deployments, Jobs, ServiceAccounts, RBAC, allow-lists and SPIRE identity definitions. SPIRE's own agent account remains SPIRE-specific.
2. **Trust-domain resolution.** Add optional blank top-level `trustDomain`. Explicit component trust-domain settings keep their existing precedence; otherwise the neutral deployment value wins over `spire.trustDomain`, followed by the current default. Retain already-issued certificate URI names; a trust-domain override requires the operator's existing certificate configuration to match.
3. **CNPG compatibility resolution.** Keep the existing `cnpg.*` public keys. Resolve effective cluster name, namespace, storage, image, database/role and credential references once for each active render path and reuse them in ancillary jobs. Explicit neutral overrides win; legacy-only configuration keeps its existing effective settings. For shared cluster fields, make the neutral values nullable and materialize the current built-in defaults in one resolver: absent/null selects the legacy active-path value before the built-in default; a supplied neutral value, including false or zero where valid, wins. Cover clusterName, namespace, instances, storageClass/storageSize and an explicit imageName override. Application database roles and secret references already use cnpg.* and remain unchanged; SPIRE datastore database/user/secret settings remain SPIRE-specific. Cross-namespace Secret mounts are not introduced; operators must retain existing namespace and certificate placement during migration. Preserve the resolved default render and add tests before changing the active cluster path. Never switch a legacy cluster into a newly named cluster or reuse a different secret silently.
4. **Deprecation warnings.** Warn at initialization when the effective configured mode is `spiffe` or the Workload API selector is `workload_api`. Warn before contacting the Workload API so unavailable sockets do not hide the notice. Use existing component loggers, avoid credentials/token/certificate output, and avoid repeated per-request warnings. Plain mTLS and filesystem certificate modes receive no SPIRE warning.
5. **New-package defaults.** Set Ash, the persisted column default, missing-mode API requests and CLI defaults/help to `mtls`. Do not backfill existing `spire` rows. Explicit `spire` remains accepted in phase one. The migration rollback restores only the column default; it does not rewrite packages created under either mode.
6. **Supported documentation path.** Describe deployment-managed mTLS as the supported model and SPIRE as deprecated compatibility. Keep instructions for explicitly opted-in SPIRE deployments available during phase one, with notices linking the migration guide. Preserve historical archived changes and existing URI-SAN naming.

## Migration Plan

The guide must separate the application control-plane database from SPIRE's own datastore. Inventory chart inputs and existing cluster/secret/resource identities first. Populate neutral overrides with the same effective identities and compare rendered resources. When moving clusters is actually necessary, require a tested backup/restore and verification of the restored database and service connectivity before any cleanup. Switching a configuration key does not move data or prove successful migration.

After mTLS workloads and onboarding have been verified, document a separate manual retirement of workload registrations, controller webhook/RBAC, SPIRE workloads, CRDs, secret and PVC. Helm does not remove CRDs automatically. No automatic deletion or live operational action belongs in this phase-one PR.

## Risks / Trade-offs

- Default-filled `cnpg.*` keys can mask legacy overrides: prove legacy-only renders retain cluster and secret identities, and cover mixed neutral/legacy overrides.
- Inconsistent account resolution can break authorization: test matching Deployment account, RBAC and registration identities for each account override.
- A default-only migration can appear correct while API/CLI inject `spire`: exercise omitted-mode creation through each public caller and the database default.
- Warning tests can accidentally require a live Workload API: capture startup logging before dependency connection and use synthetic inputs.
- The existing pending gateway proposal has different URI-SAN scope: reconcile its compatibility wording without adopting its certificate behavior or introducing tenancy features.

## Validation Strategy

All Bazel commands use `--config=remote`. Load `test-audit` before writing tests. Use only synthetic fixtures and demonstrate that new assertions reject the old behavior.

- Helm default, explicit SPIRE, blank `kv.secMode`, neutral/legacy precedence, matching account identities, namespace/cluster/secret preservation and mutually exclusive cluster rendering: `//helm/serviceradar:helm_unittest_suite_test`, `:component_gates_test`, plus existing CNPG credential/WAL checks.
- Go initialization warnings: `//go/pkg/grpc:grpc_test`, `//go/pkg/config/bootstrap:bootstrap_test`, and the relevant datasvc/CLI targets.
- Rust runtime warnings: compile and run the existing kvutil, trapd, rperf-client and flowgger Bazel test targets. Startup with a live Workload API is separate, untested live evidence; onboarding only generates mTLS configs and does not initialize a SPIRE runtime.
- Elixir effective SPIFFE/Workload API warning tests and package-default unit tests; database-backed package creation and default migration proof in hosted/RBE DB integration CI.
- Web/API/CLI omitted-mode versus explicit `spire` behavior using the issue's web-ng unit targets and existing CLI tests.
- Docs lint, OpenSpec strict validation, relevant formatting/quality checks and full `make test` before submission.
- Submit a separate phase-one PR through no-mistakes without `--yes`, retain the Treehouse lease through review/green CI, and never merge.
