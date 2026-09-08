# Change: Tenant workload operator via NATS events

## Why
Tenant services (agent-gateway, zen consumers, and future per-tenant workloads) must be deployed automatically in Kubernetes without granting the core service access to the Kubernetes API. We need an event-driven controller that reacts to tenant lifecycle changes and provisions tenant-scoped workloads safely and consistently.

## What Changes
- Add a NATS JetStream tenant lifecycle stream and event schema emitted by core.
- Introduce a Kubernetes operator that subscribes to tenant events and reconciles per-tenant workloads.
- Provision a dedicated NATS account/credentials for the operator with least-privilege access.
- Keep Docker Compose single-tenant with static workloads (no multi-tenant automation).

## Impact
- Affected specs: tenant-workload-provisioning (new)
- Affected systems: core-elx (tenant event publisher), NATS JetStream, Helm/Kubernetes deployments, new operator service
