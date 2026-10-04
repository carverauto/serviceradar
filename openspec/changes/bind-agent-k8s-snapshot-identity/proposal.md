# Change: Bind agent Kubernetes snapshots to an approved cluster identity

## Why

Agent-gateway authenticates the reporting agent over mTLS, but Kubernetes inventory ingestion currently trusts the `cluster_id` inside the agent-controlled JSON body. An enrolled agent can therefore select another cluster's row ownership key and overwrite or soft-delete that cluster's public endpoint inventory.

## What Changes

- Add a control-plane binding that assigns each Kubernetes inventory `cluster_id` to one enrolled agent and partition.
- Require agent-forwarded snapshots to match the gateway-attested agent and partition before EventWriter can upsert or soft-delete inventory rows.
- Persist the authenticated agent and partition as snapshot provenance for audit and incident response.
- Reject unbound, mismatched, or provenance-free agent-path snapshots without changing inventory state.
- Preserve the direct in-cluster inventory publisher path and durable operator-configured `cluster_id` values.
- Require operators to create bindings explicitly; existing rows are not used to infer authorization.

## Impact

- Affected specs: `k8s-public-endpoint-inventory`
- Affected code: agent-gateway Kubernetes inventory publishing, EventWriter Kubernetes public endpoint ingestion, infrastructure resources and migrations, administrative agent/inventory settings, Helm and operator documentation
- Operational impact: agent-spooled Kubernetes inventory pauses after enforcement until an administrator creates the corresponding binding
- Security findings: `commit:ccfbb34806788191a1a03a460f33369b`, `commit:cff1cdb8096c81918383e8b2a67ad287`
