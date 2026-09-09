# Change: Provision ServiceRadar and AWX automation through a declarative API

## Why

Registering an AWX controller is already possible through the ServiceRadar API,
but a usable installation still requires UI actions, internal calls, and direct
AWX administration. Customers cannot reproduce the complete configuration,
import an existing installation, or detect drift through Terraform.

The public API must own the workflow and its authorization. Terraform should
be a client of that API, with no database access or privileged RPC dependency.

## What Changes

- Complete the authenticated configuration API for unified credentials,
  controllers, Git playbook repositories, inventory discovery, membership
  review, immutable template bindings, and configuration readiness.
- Add typed, controller-scoped AWX provisioning for projects, inventories,
  inventory sources, execution environments, job templates, and the narrowly
  defined role assignments used by ServiceRadar sync and execution principals.
  Provisioning runs through the existing edge agent and credential broker.
- Require the intersection of current account RBAC, token capabilities, and
  controller/resource scope. Preserve the initiating principal across queued
  work and reauthorize before external mutations.
- Add stable resource identities, pagination, optimistic concurrency,
  idempotent retries, import/adoption, guarded deletion, and secret-free
  asynchronous operation status. Never adopt upstream objects by name alone.
- Add a first-party Terraform provider and a synthetic bootstrap example using
  only these APIs. A repeated apply must be a no-op, and refresh must surface
  drift without running playbooks.
- Expose explicit prepare/launch/status/cancel APIs for the canonical execution
  workflow. Preserve exact target membership, immutable binding review, live
  preflight, target holds, and actor authority. Configuration apply does not
  launch playbooks or automatically approve evidence.
- Keep credentials in the unified encrypted inventory. Terraform uses existing
  credential references or write-only inputs; read responses, plans, state,
  diagnostics, and audit payloads never include secret material.

## Delivery Order

The initial delivery is bounded to credentials, credential rules, controller
registrations, and playbook repository registrations. Upstream AWX provisioning
and adoption in the longer-term order below are deferred from that delivery.
See the [customer guide](../../../docs/docs/declarative-environments.md) for the
current staged workflow. Full bootstrap and live/canary acceptance remain pending.

1. Complete and test the API/authentication contract for existing ServiceRadar
   resources and current review/launch services.
2. Add bounded upstream AWX provisioning and resumable reconciliation.
3. Implement Terraform resources, import, drift detection, and a complete
   bootstrap example against the public API.
4. Verify clean bootstrap and adoption of an existing configuration, then a
   separate explicitly requested canary deployment through the canonical API.

Each stage must retain the security properties of the previous stage. No
temporary script may bypass a missing endpoint or an unfinished review gate.

## Impact

- Affected specs: new `ansible-provisioning`; existing `ansible-integration`,
  `ansible-automation`, and active targeting/preflight changes remain authoritative.
- Affected code: web-ng API routing/controllers/OpenAPI/auth, core Ansible
  resources and services, credential usage inventory, AWX command contracts and
  plugin, Terraform provider, Bazel definitions, and user documentation.
- The existing `add-platform-bootstrap` proposal owns initial platform/admin
  creation. This change starts with running ServiceRadar and AWX/AAP endpoints
  plus an operator-authorized initial API credential.
- The active callback and SSH enrollment proposals retain ownership of their
  safety gates. Provisioning them does not make an unvalidated playbook ready
  for deployment.
