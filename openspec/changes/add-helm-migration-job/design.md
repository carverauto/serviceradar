## Context
Core-elx has startup migration helpers but in Kubernetes the deployment can start multiple pods concurrently, which makes automatic migrations on boot risky. Operators currently run tenant migrations manually after deploys, which is easy to forget.

## Goals / Non-Goals
- Goals:
  - Run public and tenant migrations exactly once per Helm install/upgrade.
  - Block the Helm release on migration failures.
  - Allow operators to disable or re-run the hook job when needed.
- Non-Goals:
  - Replace the Ash migration workflow or change migration semantics.
  - Introduce a new migration orchestration service.

## Decisions
- Decision: Add a pre-install/pre-upgrade Helm hook Job to run migrations.
- Decision: Use the core-elx release image and invoke `ServiceRadar.Cluster.StartupMigrations.run!()` (or equivalent) inside the job.
- Decision: Reuse core-elx environment variables and service account so database and SPIFFE credentials resolve identically.

## Risks / Trade-offs
- Hook jobs run synchronously and can lengthen upgrades; mitigate with clear timeouts and retries.
- Migration failures will block upgrades; this is desired but must be clearly documented for operators.

## Migration Plan
- Add Helm values and template for the migration job.
- Ship updated chart and recommend enabling the hook by default.
- Document how to disable or manually re-run the job.

## Open Questions
- Should the hook run post-upgrade if pre-upgrade fails, or only pre-install/pre-upgrade?
