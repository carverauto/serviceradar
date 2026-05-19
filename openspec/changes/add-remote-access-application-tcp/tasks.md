## 1. Design And Resource Model
- [x] 1.1 Define registered HTTP/HTTPS application target resource fields, lifecycle, RBAC mapping, and relationship to inventory/device records.
- [x] 1.2 Define registered TCP target resource fields separately from HTTP application targets.
- [x] 1.3 Define application/TCP frame schemas for open, request, response metadata, data, progress, close, error, and outcome events.
- [x] 1.4 Record dependency and Teleport/source-reuse review before importing any proxy, WebSocket, or TCP helper package.

## 2. Policy, RBAC, And API
- [x] 2.1 Add RBAC permissions for opening app access, opening TCP access, managing app/TCP targets, approving sensitive access, and exporting recordings.
- [x] 2.2 Add browser/API endpoints that accept only target/session intent and reject upstream route, host, port, SNI, Host header, credential, TLS, quota, approval, and recording overrides.
- [x] 2.3 Add policy evaluation for allowed methods, path prefixes, redirects, header rules, cookie isolation, upstream TLS, quotas, approval, and recording.
- [x] 2.4 Add approval-required handling for sensitive apps, insecure upstream TLS exceptions, broad path access, upload-enabled apps, and TCP targets.

## 3. Routing And Agent Adapters
- [x] 3.1 Add gateway/agent routing for application and TCP access frames over the selected remote-access session route.
- [x] 3.2 Add an agent HTTP/HTTPS adapter that dials only registered upstreams and enforces Host/SNI/TLS/header/path/method policy.
- [x] 3.3 Add a constrained agent TCP adapter for registered targets with idle timeout, byte quotas, and connection lifecycle frames.
- [x] 3.4 Advertise `remote_access.app` and `remote_access.tcp` only when local policy enforcement is available.

## 4. UI, Recording, And Audit
- [x] 4.1 Add operator/user UI for launching registered application access sessions.
- [x] 4.2 Add TCP launch UI only for targets with an explicit browser renderer or documented client workflow.
- [x] 4.3 Persist lifecycle, request/response metadata, byte counts, failures, and policy decisions without storing bodies by default.
- [x] 4.4 Emit audit and replay events for allowed, started, request, response, denied, failed, closed, and quota-exhausted states.

## 5. Validation And Demo
- [x] 5.1 Add unit tests for resource normalization, override rejection, SSRF controls, header policy, upstream TLS, redirects, quotas, approval, and recording redaction.
- [x] 5.2 Add gateway/agent route-binding tests for app/TCP frames.
- [x] 5.3 Add agent adapter tests against local HTTP, HTTPS with test CA, redirect, and raw TCP test servers.
- [x] 5.4 Add demo proof with a private HTTP echo target reachable only from an agent.
- [x] 5.5 Run focused Go and Elixir tests plus OpenSpec validation.
