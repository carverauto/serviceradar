# Change: Add remote access application and TCP adapters

## Why
ServiceRadar remote access now covers SSH and SFTP over a selected agent route, but operators also need controlled browser access to internal HTTP services and tightly scoped TCP services that are reachable only from an edge agent.

This is high risk because a naive implementation becomes an arbitrary open proxy or SSRF primitive. Application/TCP access must therefore use registered upstream resources, trusted route selection, explicit RBAC, origin isolation, request audit, upstream TLS policy, and byte/backpressure controls.

## What Changes
- Add a ServiceRadar-owned application access model for registered HTTP/HTTPS upstreams routed through the selected agent.
- Add a constrained TCP adapter model for explicitly registered upstreams only, not browser-selected arbitrary hosts.
- Add per-upstream RBAC, approval, route binding, upstream TLS policy, header/cookie policy, request/connection audit, and recording/export controls.
- Define validation and demo proof paths before implementation starts.
- Keep Teleport application proxy code as reference only because current Teleport app server/proxy paths are AGPL-tainted by direct or transitive dependencies.

## Impact
- Affected specs: edge-architecture
- Affected code: web-ng remote-access UI/API, core remote-access resources/policy/audit/recording, agent-gateway control routing, Go agent application/TCP adapters, RBAC catalog, future Helm/demo manifests for proof targets
