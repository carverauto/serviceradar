## Context
The cache proxy has two materially different clients. BuildBuddy executors are Kubernetes pods
and already use the proxy's internal Service FQDN on plaintext gRPC port 1985. The Bazel client
can run on a laptop, Forgejo runner, or inside a BuildBuddy workflow action network namespace;
those environments have public DNS and normal egress but no dependable route to the cluster
Service CIDR.

The shared Envoy edge is managed in the adjacent GitOps repository. This repository owns the
Bazel profile, developer/CI entry points, BuildBuddy deployment runbook, and configuration-drift
test. Deployment therefore requires both repositories, but either side can roll back without
changing the executor path.

## Goals / Non-Goals
- Goals:
  - Give authenticated Bazel clients a stable TLS cache-proxy endpoint.
  - Keep the cache proxy's Kubernetes Service private and keep executor cache traffic internal.
  - Preserve all direct BuildBuddy defaults and make proxy use explicit.
  - Preserve BuildBuddy's native authentication as the authoritative access decision.
  - Make rollout and rollback independently testable.
- Non-Goals:
  - Route remote execution, BES, or the BuildBuddy UI through the cache proxy.
  - Put a public IP or NodePort directly on the cache-proxy Service.
  - Store a BuildBuddy API key, JWT, TLS private key, or other credential in this repository.
  - Enable every CI workflow in the first rollout.
  - Add a second authentication policy at Envoy.

## Decisions

### Decision: Public TLS terminates at the shared Envoy gateway
The client endpoint is `grpcs://cache-proxy.carverauto.dev:443`. Envoy presents the public
certificate and forwards HTTP/2 gRPC over the cluster network to the existing Service on port
1985. The backend Service remains `ClusterIP`, with no public load balancer or NodePort.

Consequences:
- Public traffic is encrypted and uses a stable DNS name.
- The chart does not need to own a second public address or certificate lifecycle.
- Plaintext port 1985 remains confined to the cluster network.

### Decision: Native BuildBuddy authentication remains authoritative
Envoy performs transport termination and routing only. Clients continue sending their existing
BuildBuddy credential; the cache proxy delegates remote authentication and JWT validation to the
upstream BuildBuddy instance without reparsing the JWT. The proxy's separate outbound key remains
in its Kubernetes Secret.

Consequences:
- Public exposure does not create a second credential system or a policy that can drift from
  BuildBuddy.
- Connectivity or an anonymous Capabilities response is not sufficient validation. A canary must
  perform a protected ActionCache/CAS operation with valid credentials and must confirm invalid
  credentials are rejected.

### Decision: The Bazel profile stays opt-in
Only `--remote_cache` and `--remote_bytestream_uri_prefix` belong to `build:cache_proxy`.
`build:ci`, `build:remote`, normal Make targets, the executor, and BES remain unchanged.

Consequences:
- A public-route outage rolls back immediately by omitting `--config=cache_proxy`.
- CI adoption can proceed job by job after a developer/workflow canary.
- The in-cluster executor-to-proxy path continues carrying the majority of cache traffic even
  when no Bazel client opts in.

### Decision: Make targets share canonical recipes and workspace scope
`build-workspace-cache` reuses the `build-workspace` recipe and target scope while selecting the
approved optimized CI flags plus `build:cache_proxy`. `test-cache` reuses the `test` recipe,
workspace scope, and test filters while adding `build:cache_proxy`. Shared arguments are declared
once and the aliases override only their intended flag variable.

Consequences:
- The cache aliases cannot silently omit new canonical unit-test filters or workspace scope.
- Help output makes the opt-in discoverable without changing a default target.

## Risks / Trade-offs
- The endpoint is reachable over the public Internet. TLS protects transport and BuildBuddy's
  native authentication protects cache RPCs; a configuration test prevents accidental plaintext
  client configuration.
- A shared-gateway listener or certificate regression can make the opt-in path unavailable.
  Default builds and the internal executor cache path remain independent rollback paths.
- A successful TCP/TLS probe can hide an authorization failure. Validation uses a real Bazel
  cache operation and checks rejection behavior rather than relying on Capabilities alone.
- Enabling all workflows at once would increase blast radius. Adoption remains staged and
  explicitly configured per job.

## Migration Plan
1. Apply the GitOps listener, certificate, DNS, route, and backend reference while leaving the
   cache-proxy Service private.
2. Verify DNS, certificate trust, and HTTP/2 ALPN without sending a credential.
3. Run authenticated workspace build and canonical unit-test canaries with
   `--config=cache_proxy`; verify protected RPC behavior and proxy metrics.
4. Enable selected CI jobs by adding the config selection to their ignored/generated remote rc
   files, without copying a credential into source control.
5. Roll back clients first by removing the opt-in, then remove the public route if needed. Do not
   alter executor `cache_target` during rollback.

## Open Questions
- None. Public DNS, shared-gateway TLS termination, native BuildBuddy authentication, and opt-in
  client adoption are approved constraints for this change.
