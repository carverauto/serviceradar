## Context
Teleport-style Kubernetes access lets users reach private clusters after SSO/RBAC checks. ServiceRadar should provide comparable workflows while preserving the existing agent-routed remote-access shape:

```text
browser Kubernetes UI or future kubectl connector
  -> web-ng Kubernetes access endpoint
  -> core policy/session/recording manager
  -> agent-gateway selected route
  -> existing agent-initiated control stream
  -> agent Kubernetes adapter
  -> registered private Kubernetes API server
```

The adapter must never accept browser-supplied API server URLs, kubeconfigs, bearer tokens, client certificates, namespaces outside policy, selected routes, or recording settings. Cluster connection, identity translation, and policy must come from trusted ServiceRadar resources.

## Goals
- Provide controlled access to registered private Kubernetes clusters through an edge agent.
- Support API read/browse, pod logs, pod exec, and pod port-forward with explicit namespace/resource/verb scope.
- Preserve one actor, one access session, one selected agent/gateway route, one Kubernetes cluster target, one credential mode, one policy snapshot, and one audit/recording boundary.
- Prefer actor-preserving identity with Kubernetes impersonation or short-lived client certificates.
- Keep cluster credentials and user tokens out of browser storage and persisted session metadata.
- Record Kubernetes request/session metadata by default without storing response bodies or stream payloads unless explicit recording policy enables them.
- Keep implementation ServiceRadar-owned unless a future exact-file Teleport vendoring review approves a small Apache-compatible utility.

## Non-Goals
- Do not expose arbitrary kubeconfig proxying.
- Do not let users upload kubeconfigs or select API server URLs at session time.
- Do not grant broad cluster-admin behavior through a shared connector identity.
- Do not implement Helm, kubectl plugin distribution, Kubernetes operator management, or workload deployment workflows in the first slice.
- Do not implement database, RDP, or generic TCP behavior in this proposal.
- Do not copy current Teleport `lib/kube/proxy` implementation code.

## Access Modes
The first implementation should support browser-mediated workflows:

- API browse: list/get/watch approved resources.
- Logs: stream `pods/log` for approved namespaces, pods, and containers.
- Exec: open approved `pods/exec` sessions with shell/command policy, TTY policy, timeout, and recording controls.
- Port-forward: open approved `pods/portforward` streams with local UI controls, port allowlists, byte quotas, and idle timeout.

A later native `kubectl` connector can reuse the same target, route, identity, policy, approval, and recording model. It should use a short-lived local listener or generated kubeconfig that expires quickly and cannot change the registered target.

## Resource Model
The first implementation should introduce a registered Kubernetes cluster target resource, or extend the remote-access target model, with:

- stable cluster target ID
- display name and inventory/device relation
- selected agent or allowed agent set
- Kubernetes API server URL from trusted inventory/policy
- cluster CA bundle reference and TLS server name
- connector credential mode: service account token, mTLS client certificate, or future workload identity/provider token
- actor identity mode: Kubernetes impersonation, short-lived client certificate, or OIDC token passthrough where the target cluster trusts the same IdP
- allowed impersonation users, groups, and extra fields derived from ServiceRadar actor traits
- namespace, resource, verb, subresource, label-selector, and field-selector policy
- exec command allow/deny policy, TTY policy, environment policy, and timeout policy
- log stream policy, historical line/time limits, and byte quotas
- port-forward namespace/pod/service/port policy, max streams, max bytes, and idle timeout
- approval, recording, retention, and export policy

## Credential Custody
Browser clients must not receive target cluster bearer tokens, connector kubeconfigs, or connector private keys.

Preferred identity modes:

- Kubernetes impersonation: the agent uses a narrowly scoped connector credential that can impersonate approved users/groups, and the target cluster authorizes the request as the real actor.
- Short-lived client certificates: ServiceRadar issues or brokers a client cert with actor and group identity when the target cluster supports that trust path.
- OIDC token passthrough: a future mode may pass a short-lived user token only when the target cluster trusts the same IdP and token handling can remain memory-only.

Fallback connector credentials must be stored only in the approved secret-management path and delivered to the selected agent as session-scoped grants when possible. The agent must not persist connector tokens, generated kubeconfigs, or generated client private keys to disk.

## Policy Enforcement
ServiceRadar must enforce policy before dispatching any request and should also rely on Kubernetes authorization in the target cluster.

Controls:

- map ServiceRadar roles and Authentik/OIDC groups to allowed Kubernetes users/groups/extra fields
- require explicit namespace/resource/verb/subresource grants
- deny wildcard cluster-scope access unless a target policy explicitly allows it
- constrain `pods/exec` commands, shells, TTY, containers, duration, and recording mode
- constrain `pods/log` history windows, follow mode, selected containers, and byte limits
- constrain `pods/portforward` targets, ports, stream count, bytes, and idle timeout
- reject browser-supplied kubeconfigs, API server URLs, tokens, certificates, impersonation headers, namespace overrides outside policy, and route overrides
- terminate sessions when approval, route, identity, or policy is revoked

## Recording And Audit
Kubernetes access recording stores metadata by default:

- actor, session, route, cluster target, namespace, resource, subresource, verb, and selected object
- impersonated user/groups or certificate subject when used
- approval and reviewer metadata when required
- request timing, status, response size, stream byte counts, and termination reason
- exec command metadata and TTY mode
- port-forward destination and byte counts

Response bodies, log lines, exec stream payloads, and port-forward payloads are sensitive and must not be persisted by default. Exec transcript recording and log-content capture require explicit policy, retention, RBAC, and export controls.

## Source Reuse
Current Teleport Kubernetes access code is not approved for import:

```bash
TELEPORT_SRC=$HOME/src/teleport scripts/check-teleport-license-paths.sh \
  github.com/gravitational/teleport/lib/kube/proxy \
  github.com/gravitational/teleport/lib/kube/proxy/forwarder \
  github.com/gravitational/teleport/lib/kube/proxy/responsewriters
```

The current checkout reports AGPL transitive dependencies through Teleport API/types/auth/logging/proto paths. Treat Teleport behavior as product and architecture reference only. Use Kubernetes upstream Go client libraries and ServiceRadar-owned policy/session code after dependency review.

## Validation
- Unit tests for cluster target/resource normalization rejecting client-selected API servers, kubeconfigs, tokens, certificates, impersonation headers, route, quota, and recording overrides.
- RBAC and approval tests proving access is denied without target permission and approval where required.
- Policy tests for namespaces, resources, verbs, subresources, labels, fields, exec commands, log history, and port-forward ports.
- Agent adapter tests with a local Kubernetes API test server or kind cluster proving TLS verification, impersonation headers, token non-persistence, request denial, stream cancellation, and route loss cleanup.
- Audit/recording tests proving metadata is recorded and payload/body content is not retained by default.
- Demo proof with a private Kubernetes API reachable only from an agent and Authentik-backed actor/group mapping.
