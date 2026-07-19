# Change: Make periodic reconciliation recover quietly and truthfully

## Why

Demo exposes two recurring control-plane failures that are not transient workload
errors. Legacy Proxmox rules configured with insecure transport are correctly
blocked, but the minute worker reports each policy rejection as a failed agent and
issues a credential grant before discovering the rejection. Separately, stale Oban
conflict recovery uses a bulk string update against the PostgreSQL job-state enum;
the update fails, its exception is swallowed, and every scheduler pass repeats an
opaque "not recovered" warning.

## What Changes

- Preflight provider policy before issuing credential grants.
- Treat known fail-closed Proxmox policy rejections as stable, counted skip reasons
  while keeping unexpected materialization failures actionable.
- Recover stale executing Oban conflicts under a row lock through the Oban schema
  changeset so PostgreSQL enum casting is correct and races remain safe.
- Preserve and report recovery errors instead of swallowing them.

## Impact

- Affected specs: `agent-config`, `job-scheduling`
- Affected code: Proxmox credential profile/materializer and shared Oban support
- Operational impact: invalid legacy Proxmox rules remain disabled until their TLS
  or SSH verification policy is repaired; they stop generating grant churn and
  per-minute false failure warnings.
- Tracking issue: Forgejo #4637
