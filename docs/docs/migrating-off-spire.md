---
title: Migrating off SPIRE
sidebar_position: 5
---

# Migrating off SPIRE

SPIFFE/SPIRE runtime support is deprecated. New deployments and new edge onboarding packages use mTLS with ServiceRadar's deployment-managed CA. Phase one retains explicit SPIRE runtime configuration and existing `spire` packages, and logs a warning with this guide's URL. Runtime removal and manifest/CRD deletion follow in separate phases.

The `spiffe://serviceradar.local/...` URI SANs issued by the in-house CA are still used by certificate identity resolution, NATS leaf authentication and datasvc authorization. Keep those identities, trust roots and role bindings. Removing SPIRE does not require renaming certificate URIs.

## Already using mTLS

Keep `spire.enabled=false`, `spiffe.mode=filesystem`, `kv.secMode=mtls`, `coreClient.secMode=mtls` and `webNg.datasvc.secMode=mtls`. No cluster move or SPIRE cleanup is needed if those resources were never installed. Existing package rows are not rewritten by the new database default.

## Neutral chart values

| Neutral key | Compatibility fallback |
| --- | --- |
| `serviceAccounts.<component>` | Corresponding `spire.*ServiceAccount`, then built-in account; the agent retains its existing `agent.serviceAccount` override |
| `trustDomain` | `spire.trustDomain`, then the existing chart default; explicit component trust-domain overrides retain their precedence |
| `cnpg.clusterName`, `cnpg.instances`, `cnpg.storageClass`, `cnpg.storageSize` | Null/absent retains the active `spire.postgres.*` field, then the built-in default |
| `cnpg.namespace` | Blank retains the active legacy `spire.namespace` or the Helm release namespace |
| `cnpg.imageName` | Explicit image overrides either cluster render path |

Application database usernames and credentials already use `cnpg.*`. SPIRE's own datastore username, database and credential secret remain under `spire.postgres.*` during compatibility. A neutral key is an override, not a data migration. Keep the existing namespace and Secret placement; Kubernetes cannot mount Secrets from another namespace.

## Existing SPIRE deployments

1. Inventory effective values, the current CNPG Cluster name/namespace, PVCs, databases, users, Secrets, workload accounts and issued certificate identities. Keep secrets in the existing credential tooling; do not export them into source control or support artifacts.
2. Render the same chart version with the proposed neutral overrides. Compare cluster/PVC identity, image, storage, roles, certificate mounts and service endpoints before applying it. Populate overrides with the same effective values first.
3. When disabling `spire.enabled` or `spire.postgres.enabled`, the chart switches from the legacy cluster template to its native CNPG template. Set neutral cluster fields explicitly to preserve the existing Cluster identity and review the full rendered spec. Retain the application database and its credential references. Reusing a name does not prove the new spec is equivalent.
4. If a different cluster is required, take and verify a backup, restore to the intended cluster, and test application schema, credentials and service connectivity before switching traffic. Retain the old cluster until verification is complete. Do not delete a PVC to make a migration appear successful.
5. Configure deployment-managed runtime certificates, `mtls` service modes and filesystem certificate loading. Verify internal RPCs, agent gateway registration, datasvc authorization and NATS leaf authentication using the intended new certificates. Issue a new mTLS onboarding package and verify enrollment.
6. Retire SPIRE resources only after those checks pass. Existing `spire` onboarding packages can be revoked and replaced with mTLS packages when needed; changing the default does not convert them.

## Manual cluster cleanup

Cleanup is separate from the chart value change and is never automatic in this phase. Identify resources belonging to the old installation before removing workload registrations, controller webhooks/RBAC, SPIRE server/agent/controller workloads, bundle/config objects and SPIRE-only Secrets. Remove a SPIRE datastore/PVC only after proving it is not the application's shared database and its backup is usable.

Helm does not automatically remove installed CRDs. Remove `spire.spiffe.io` CRDs only after checking for remaining custom resources and other consumers. Retain shared runtime CA/certificate Secrets, application credentials, CNPG storage and load-bearing certificate URI identities.

Use the [operator verification checklist](https://github.com/carverauto/serviceradar/blob/staging/docs/spire-migration-runbook.md) to record the render comparison, connectivity evidence and cleanup decision.
