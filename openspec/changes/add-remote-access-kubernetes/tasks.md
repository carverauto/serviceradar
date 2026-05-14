## 1. Design And Data Model
- [ ] 1.1 Define registered Kubernetes cluster target resources, including route, TLS, connector credential, actor identity, namespace/resource/verb policy, approval, and recording fields.
- [ ] 1.2 Define Kubernetes session lifecycle, typed frames, stream cancellation semantics, and route binding shared by web-ng, core, agent-gateway, and agent.
- [ ] 1.3 Define credential and identity modes for impersonation, short-lived client certificates, OIDC token passthrough, and connector credential fallback.
- [ ] 1.4 Record exact dependency choices for Kubernetes client support before implementation.

## 2. Policy, RBAC, And API
- [ ] 2.1 Add Kubernetes target RBAC and approval checks that bind actor, target, route, policy snapshot, identity mode, and credential grant to one session.
- [ ] 2.2 Add APIs for listing authorized Kubernetes targets, creating sessions, browsing approved resources, streaming logs, starting exec, starting port-forward, cancelling streams, and closing sessions.
- [ ] 2.3 Add policy enforcement for namespaces, resources, verbs, subresources, selectors, exec commands, log history, port-forward ports, timeouts, and byte quotas.
- [ ] 2.4 Add audit/recording metadata events for API, log, exec, and port-forward activity.

## 3. Agent Route And Kubernetes Adapter
- [ ] 3.1 Add typed Kubernetes frames to the agent-gateway route without reusing terminal byte frames blindly.
- [ ] 3.2 Implement the agent Kubernetes adapter for registered clusters only, including TLS verification and connector credential use.
- [ ] 3.3 Implement impersonation and short-lived identity handling without persisting connector tokens, generated kubeconfigs, or generated client private keys to disk.
- [ ] 3.4 Add stream cancellation, cleanup, backpressure, byte quotas, and route-loss behavior for logs, exec, and port-forward.

## 4. Operator And User Experience
- [ ] 4.1 Add web-ng target administration for Kubernetes cluster targets and policy fields.
- [ ] 4.2 Add user workflows for approved API browse, logs, exec, and port-forward sessions with visible cluster, namespace, identity, policy, quota, and approval state.
- [ ] 4.3 Add recording/audit views for Kubernetes session lifecycle and request/stream metadata without response bodies or stream payloads by default.
- [ ] 4.4 Add operator docs for registering clusters, configuring impersonation RBAC or client-cert trust, Authentik-backed identity mapping, and session policy.

## 5. Validation And Demo
- [ ] 5.1 Add unit tests for resource normalization, override rejection, RBAC, approval, policy matching, quota enforcement, and audit records.
- [ ] 5.2 Add Kubernetes integration tests using a local API server or kind cluster for TLS, impersonation, namespace/resource/verb denial, logs, exec, port-forward, cancellation, and cleanup.
- [ ] 5.3 Add route/session tests proving frames are accepted only on the selected route and terminate on revocation or route loss.
- [ ] 5.4 Add a demo proof path with a private Kubernetes API reachable only from an agent.
- [ ] 5.5 Update the Teleport parity matrix after the Kubernetes slice is implemented and validated.
