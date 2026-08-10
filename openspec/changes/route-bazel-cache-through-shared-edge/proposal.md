# Change: Route opt-in Bazel cache traffic through the shared public edge

## Why
The BuildBuddy cache proxy already serves executor traffic inside Kubernetes, but Bazel clients
running on developer workstations or in isolated workflow network namespaces cannot reach its
ClusterIP. A stable public TLS endpoint lets those clients use the same authenticated cache
without publishing the proxy's plaintext service or changing the default build path.

## What Changes
- Point the existing opt-in `build:cache_proxy` profile at
  `grpcs://cache-proxy.carverauto.dev:443` while preserving the upstream BuildBuddy bytestream
  URI prefix.
- Keep `build:ci`, remote execution, BES, `make test`, and ordinary workspace builds on their
  existing direct BuildBuddy path.
- Add discoverable Make targets that reuse the canonical full-workspace recipes and scopes. The
  build canary uses the approved optimized CI flags plus the cache-proxy profile; the test canary
  adds the cache-proxy profile to the canonical unit-test flags and filters.
- Document the public TLS/private backend boundary, native BuildBuddy authentication, secret
  custody, staged validation, and client-first rollback.
- Add a Bazel test that prevents endpoint, profile-isolation, and Make-target drift.

## Impact
- Affected specs:
  - `bazel-cache-routing` (new)
- Affected code and operations:
  - `.bazelrc`
  - `Makefile`
  - `BUILD.bazel`
  - `buildbuddy.yaml`
  - `k8s/buildbuddy/README.md`
  - `k8s/buildbuddy/values-cache-proxy.yaml`
  - the shared Envoy gateway and DNS configuration maintained in the GitOps repository
