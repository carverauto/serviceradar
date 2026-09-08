# Change: Scale the demo control plane to a true clustered topology

## Why
The `demo` namespace still runs the main control-plane workloads as single replicas:
- `serviceradar-core`
- `serviceradar-web-ng`
- `serviceradar-agent-gateway`
- `serviceradar-nats`

That leaves `demo` with obvious single-point-of-failure behavior and means we are not exercising the distributed topology that the Elixir services already claim to support. The current chart and runtime configuration show that `core`, `web-ng`, and `agent-gateway` are already wired for ERTS clustering, but they are still deployed as singleton pods. There are also real architectural risks that make naive replica bumps unsafe:
- `core` currently hardcodes coordinator duties in the Helm deployment, so multiple replicas would try to act as the coordinator unless we define leader/singleton behavior explicitly.
- live gateway and agent views still depend on node-local tracker state in ETS, which can become inconsistent or incomplete when pods are distributed or restarted.
- `core` migrations are still driven by a per-pod init container path, which is not an acceptable contract for a multi-replica rollout.
- NATS is still a single `Deployment` with one PVC instead of a clustered JetStream topology.

We need a deliberate HA proposal before implementation so the demo environment can run multiple replicas without duplicate schedulers, split-brain coordinator behavior, or fragile message-bus state.

## What Changes
- Define the target clustered demo topology for `core`, `web-ng`, `agent-gateway`, and NATS.
- Require Helm and runtime behavior that allows `core`, `web-ng`, and `agent-gateway` to run as a multi-replica ERTS cluster in Kubernetes.
- Require `core` singleton responsibilities such as coordination, scheduling, and other cluster-authoritative duties to remain single-owner even when multiple `core` replicas exist.
- Require live gateway and agent state used by operator-facing pages to remain available across replica placement, restarts, and load-balanced web requests.
- Replace the single-pod demo NATS deployment with a clustered NATS/JetStream topology suitable for at least a 3-node demo deployment.
- Define rollout and failure-mode validation for pod restarts, rolling upgrades, and single-node loss in the replicated demo topology.

## Impact
- Affected specs:
  - `ash-cluster`
  - `job-scheduling`
  - `agent-registry`
  - `nats-clustering` (new)
- Affected code:
  - `helm/serviceradar/templates/core.yaml`
  - `helm/serviceradar/templates/web.yaml`
  - `helm/serviceradar/templates/agent-gateway.yaml`
  - `helm/serviceradar/templates/nats.yaml`
  - `helm/serviceradar/values*.yaml`
  - `elixir/serviceradar_core/**`
  - `elixir/web-ng/**`
  - `elixir/serviceradar_agent_gateway/**`
  - cluster/runtime validation docs and demo rollout playbooks
