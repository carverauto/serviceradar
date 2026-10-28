# SPIRE deprecation operator checklist

This is a manual checklist for an existing SPIRE deployment. New and existing mTLS deployments do not need a SPIRE migration. For chart compatibility, value mapping and upgrade cleanup behavior, see [Migrating off SPIRE](docs/migrating-off-spire.md).

1. Record the deployed chart version and effective non-secret values. Identify the existing CNPG Cluster namespace/name, application database, SPIRE datastore, PVCs and credential references. Keep secret material in the approved credential tooling.
2. Compare the deployed chart with the target chart using neutral overrides before upgrading. Compare Cluster metadata/spec, storage size/class, instance count, image, users, Secret references, workload accounts and certificate URI identities. Use the value mapping in the migration guide; record explicit settings for every legacy override.
3. Verify a backup and restore before any actual cluster move. Record database/schema verification and a successful connection from the affected application services. Preserve the previous cluster and PVC until the new path is proven.
4. Configure mTLS and filesystem certificates. Verify core-to-datasvc RPC, gateway/agent registration, NATS leaf authentication and datasvc role authorization with the new configuration. Confirm the test began after rollout completed, and re-query the resulting registration/state.
5. Create and enroll a synthetic test component from a new mTLS package. Check the persisted package security mode and certificate identity; do not use a real captured device value as a fixture. Replace existing SPIRE packages deliberately if needed.
6. Inventory remaining SPIRE custom resources, webhook configurations, RBAC, workloads, bundle/config objects, Secrets and storage. Prove no active consumer uses each resource before its removal. Keep the application CNPG cluster, shared runtime credentials and certificate URI naming intact.
7. Review reconciler-driven removals during the upgrade and manually remove remaining SPIRE-only resources. CRDs require explicit cleanup after all custom resources and other consumers are accounted for. Re-check absence after the owning reconciler runs, then repeat application connectivity and onboarding verification.

A green render is configuration evidence, not proof of a live migration. Record each check as passed, failed or untested with its artifact and timestamp. A failed connectivity, backup/restore or remaining-consumer check stops cleanup.
