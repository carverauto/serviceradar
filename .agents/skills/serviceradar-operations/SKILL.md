---
name: serviceradar-operations
description: Use for ServiceRadar operational work involving demo/farm clusters, BuildBuddy failures, runbooks, rollouts, or sysmon sampling.
user-invocable: false
metadata:
  internal: true
---

# ServiceRadar Operations

## Operational Runbooks

Step-by-step procedures live in [docs/agent-runbooks.md](docs/agent-runbooks.md), so that
this file stays inside its context budget: demo namespace Helm refresh (including the
web-ng-only fast path), Docker Compose refresh, local development against Docker CNPG,
web-ng visual testing and remote dev, the local mTLS ERTS cluster, edge onboarding
testing, the release playbook, CNPG database access, and the SRQL fixture lifecycle.

Architecture and data-pipeline background is in `docs/docs/` — `architecture.md`,
`data-pipeline.md`, `edge-model.md`. (Earlier revisions of this file pointed at
`docs/docs/agents.md`, which does not exist; `openspec/project.md` still cites it.)

## Common Commands & Tips

- Check demo pods: `kubectl get pods -n demo`.
- Scale sync: `kubectl scale deployment/serviceradar-sync -n demo --replicas=<n>`.
- GH client is installed and authenticated
- 'bb' (BuildBuddy) client is available for any build issues. `bb view`
  does not need `.bazelrc.remote`; `bazel --config=ci` / `--config=remote` does.
- bazel is our build system, we use it to build and push images. Isolated
  checkouts must symlink `.bazelrc.remote` from the primary clone or they
  never hit RBE (Hard Rules).
- Sysmon-vm hostfreq sampler buffers ~5 minutes of 250 ms samples; keep gateways querying at least once per retention window so cached CPU data stays fresh.
