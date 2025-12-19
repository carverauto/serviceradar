## 1. Inventory
- [x] 1.1 Audit Docker Compose/Helm/K8s manifests for Kong services, routes, and config references.
- [x] 1.2 Identify docs/runbooks that still describe Kong-based routing or JWT enforcement.

## 2. Remove Kong from deployments
- [x] 2.1 Remove Kong services and config from docker compose stacks (including spiffe variants).
- [x] 2.2 Update Caddy/Nginx routing to send API traffic directly to core and SRQL as needed.
- [x] 2.3 Remove Kong templates from Helm and K8s demo manifests.

## 3. Packaging cleanup
- [x] 3.1 Remove Kong package artifacts from packaging configs and build scripts.
- [x] 3.2 Drop Kong-related config files that are no longer used.

## 4. Docs
- [x] 4.1 Update architecture docs to reflect direct routing without Kong.
- [x] 4.2 Update installation/runbook docs to remove Kong references.

## 5. Validation
- [ ] 5.1 Validate docker compose stack starts without Kong and web-ng login/API flows work.
- [ ] 5.2 Validate Bazel build/push still succeeds after Kong removal.
