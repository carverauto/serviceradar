# BuildBuddy Executor Setup

This directory contains the Helm configuration for the BuildBuddy executor deployment.

## Overview

The BuildBuddy executors connect to the org's own BuildBuddy instance at
`grpcs://carverauto.buildbuddy.io:443` (`config.executor.app_target` in `values.yaml`) to
provide Remote Build Execution (RBE) for the Bazel builds.

**Not** `remote.buildbuddy.io` — that is BuildBuddy's shared cloud, a different frontend
(34.98.106.0 vs 34.98.126.170). The executor's `app_target` and the Bazel client's
`--remote_executor` must name the *same* instance: the fleet registers with that instance's
scheduler, so if they diverge the executors sit idle and the build silently runs somewhere
else. The client side lives in `//.bazelrc` under `build:remote_base`, which every remote
profile (`ci`, `remote`, `el9`) inherits.

## Configuration

- **Location**: `k8s/buildbuddy/values.yaml`
- **Namespace**: `buildbuddy`
- **Release Name**: `buildbuddy`

Key fields you should see in `values.yaml`:

```yaml
resources:
  requests:
    cpu: "8"
    memory: "16Gi"
    ephemeral-storage: "45Gi"
  limits:
    cpu: "16"
    memory: "32Gi"
    ephemeral-storage: "50Gi"

extraVolumes:
  - name: cache-volume
    hostPath:
      path: /var/lib/buildbuddy/cache
      type: DirectoryOrCreate

extraVolumeMounts:
  - name: cache-volume
    mountPath: /cache

config:
  executor:
    local_cache_directory: /cache
    local_cache_size_bytes: 50000000000
    root_directory: /cache/remotebuilds/
```

### Current Setup

- **Replicas**: 3 (autoscaler target queue length = 5, min=3, max=10)
- **Resources per executor**:
  - CPU: 8-16 cores (request-limit)
  - Memory: 16-32Gi (request-limit)
  - Ephemeral Storage: 20-25Gi (request-limit)
- **Cache path**: `/cache` (hostPath `/var/lib/buildbuddy/cache` on each node)
- **Remote builds dir**: `/cache/remotebuilds/`

### Node Affinity

The deployment is configured to avoid `k8s-cp3-worker3` due to disk pressure issues.

## Setup

### Prerequisites

- Kubernetes cluster with `buildbuddy` namespace created
- Helm 3.x installed
- BuildBuddy API key (get from BuildBuddy dashboard)

### Initial Setup

1. **Create the namespace** (if it doesn't exist):
   ```bash
   kubectl create namespace buildbuddy
   ```

2. **Create values.yaml from template**:
   ```bash
   cp k8s/buildbuddy/values.yaml.template k8s/buildbuddy/values.yaml
   ```

3. **Edit values.yaml and add your API key**:
   ```bash
   # Edit the api_key field in values.yaml
   vim k8s/buildbuddy/values.yaml
   ```

   Or use the deployment script:
   ```bash
   ./k8s/buildbuddy/deploy.sh
   ```

> **⚠️ SECURITY**: `values.yaml` is gitignored and should NEVER be committed. Only the template is versioned.

### Deployment

**Prerequisite: add the BuildBuddy chart repo.** Both options below install
`buildbuddy/buildbuddy-executor`, which resolves against a locally configured Helm
repo. Without this you get `Error: repo buildbuddy not found`:

```bash
helm repo add buildbuddy https://helm.buildbuddy.io
helm repo update buildbuddy
```

**Option 1: Using deploy.sh script** (Recommended)
```bash
# First, create a Kubernetes secret with your API key
kubectl create secret generic buildbuddy-api-key \
  -n buildbuddy \
  --from-literal=api-key='YOUR_API_KEY_HERE'

# Then run the deployment script
./k8s/buildbuddy/deploy.sh
```

**Option 2: Manual deployment**
```bash
# Set API key in values.yaml first, then:
helm upgrade --install buildbuddy buildbuddy/buildbuddy-executor \
  -n buildbuddy \
  -f k8s/buildbuddy/values.yaml
```

### Add auto scalar

```bash
kubectl apply -f k8s/buildbuddy/scaledobject.yaml

kubectl get scaledobject,hpa -n buildbuddy
```

### Verify Status

```bash
# Check pods
kubectl get pods -n buildbuddy -l app.kubernetes.io/name=buildbuddy-executor

# Check logs
kubectl logs -n buildbuddy -l app.kubernetes.io/name=buildbuddy-executor --tail=50

# Check HPA
kubectl get hpa -n buildbuddy
```

## Troubleshooting

### Pods Being Evicted

If pods are being evicted due to resource pressure:
1. Check node resources: `kubectl describe node <node-name>`
2. Common causes:
   - **Ephemeral storage exhaustion**: Ensure `resources.requests/limits.ephemeral-storage` reflect 20Gi/25Gi
   - **Memory pressure**: Adjust memory limits
   - **Disk pressure**: Check node disk usage
3. Confirm the cache mount is present: `kubectl exec -n buildbuddy <pod> -- ls -la /cache`
4. Reduce resource requests/limits in `values.yaml` if needed
5. Add node affinity to avoid problematic nodes
6. Reduce cache size (`local_cache_size_bytes`)
7. Clean up evicted pods: `kubectl delete pods --field-selector status.phase=Failed -n buildbuddy`

### Cache Backing Storage

- Executors mount a hostPath volume named `cache-volume` at `/cache`.
- The host path (`/var/lib/buildbuddy/cache`) is created per node and is not shared across nodes.
- If a node runs out of disk, resize the node storage or adjust `local_cache_size_bytes`.

### Connection Issues

If executors can't connect to remote.buildbuddy.io:
1. Verify API key is correct in `values.yaml`
2. Check executor logs: `kubectl logs -n buildbuddy <pod-name>`
3. Verify network connectivity from pods

## Monitoring

Executors expose Prometheus metrics on port 9090:
- Endpoint: `http://<pod-ip>:9090/metrics`
- Annotations are set for automatic Prometheus scraping

## Executor Pods vs. Bazel Action Image

Two different container images are involved in remote execution:

1. **BuildBuddy executor pods (Helm)** – run the BuildBuddy binary and should stay on the upstream image `gcr.io/flame-public/buildbuddy-executor-enterprise:<tag>` unless we intentionally rebuild the executor ourselves.
2. **Bazel action image** – the toolchain container (`registry.carverauto.dev/serviceradar/rbe-executor:<tag>`) that Bazel runs for each action via `exec_properties`. This is where we add compilers, Postgres libraries, etc.

Only the Bazel action image is customized today. After updating `docker/Dockerfile.rbe`:

1. Build and push the image (requires Harbor access; see `scripts/docker-login.sh`):
   ```bash
   docker buildx build \
     --platform linux/amd64 \
     -f docker/Dockerfile.rbe \
     -t registry.carverauto.dev/serviceradar/rbe-executor:v1.0.24.1 \
     --push .
   ```
2. Bump the tag everywhere it is referenced for Bazel (`MODULE.bazel`, `MODULE.bazel.lock`, `BUILD.bazel`, `build/rbe/BUILD`, `build/platforms/BUILD.bazel`, `buildbuddy.yaml`, and `warmup_additional_images` in `k8s/buildbuddy/values.yaml`).
   The `rbe-executor-el9` tag in `.bazelrc` and `build/platforms/BUILD.bazel` is a *different* image
   (built from `docker/Dockerfile.rbe-ora9`) and moves independently — do not bump it in lockstep.
3. (Optional) If we ever choose to run a custom executor pod image, update `k8s/buildbuddy/values.yaml` and redeploy via `./k8s/buildbuddy/deploy.sh`.

Remote builds automatically use the refreshed Bazel action image as soon as the new tag is referenced in the Bazel exec platform configs—no Helm redeploy is required for that step.

## Two fleets

There are **two helm releases of the same chart** in this namespace, and they must not be
confused:

| release | values | pool | replicas | mem requests | hostPath cache | runs |
|---|---|---|---|---|---|---|
| `buildbuddy` | `values.yaml` | default (`""`) | 3, KEDA 3-10 | 16Gi | `/var/lib/buildbuddy/cache` | build actions |
| `buildbuddy-workflows` | `values-workflows.yaml` | `workflows` | 1, unscaled | 56Gi | `/var/lib/buildbuddy/cache-workflows` | the CI runner |

The workflow runner wants ~32GB — a Bazel server over ~2,000 targets, `--jobs=100` of input
uploads over the WAN, and every `no-remote-exec` target executing locally. Putting that on the
build fleet means either it cannot be placed (16Gi advertised) or, if you size the build fleet
up, one runner reserves 56Gi on all three pods and squeezes out the very fan-out it is driving.

Deploy the workflow fleet with the same API key the build fleet uses:

```bash
API_KEY=$(kubectl get secret buildbuddy-api-key -n buildbuddy -o jsonpath='{.data.api-key}' | base64 -d)

helm upgrade --install buildbuddy-workflows buildbuddy/buildbuddy-executor \
  -n buildbuddy \
  -f k8s/buildbuddy/values-workflows.yaml \
  --set config.executor.api_key="$API_KEY"
```

`deploy.sh` deliberately does not do this — it hardcodes `RELEASE_NAME=buildbuddy` and would
overwrite the build fleet with these values.

Four things to know before deploying:

- **The release name and the `-f` must agree, and nothing checks it.** Because the workflow fleet has no scripted path, its upgrades are typed by hand, and `helm upgrade buildbuddy-workflows ... -f values.yaml` succeeds silently. It strips `poolName` (the pod joins the default pool, `workflows` goes empty), sets `replicas: 3`, and reverts to the shared cache hostPath — with no error until the next staging push reports `no registered executors in pool "workflows"`. The mirror-image slip is worse: an edit to `values.yaml` applied to the *workflows* release leaves the build fleet silently un-upgraded, on values weeks old. Both have happened. After either deploy, diff intent against reality: `helm get values <release> -n buildbuddy`.
- **Check a node can hold 56Gi first.** `kubectl get nodes -o custom-columns='NODE:.metadata.name,MEM:.status.allocatable.memory'`. A request nothing can satisfy leaves the pod `Pending` and the workflow fails with the same `no registered executors` message as before, only now after a helm deploy.
- **The hostPath differs on purpose.** This pod can land on a node already running a build executor. BuildBuddy's filecache assumes it owns its directory and evicts against `local_cache_size_bytes`; two executors sharing one directory means two eviction loops deleting each other's entries while both believe they are under budget.
- **KEDA does not touch this release.** `scaledobject.yaml` targets the Deployment `buildbuddy-buildbuddy-executor` by name, and a second release produces a different name. Rename this release into a collision and KEDA will start driving it to `minReplicaCount: 3`.

Verify after deploying. A `Running` pod proves scheduling, not pool registration — check both:

```bash
kubectl get deploy -n buildbuddy
#   buildbuddy-buildbuddy-executor             3/3   <- untouched
#   buildbuddy-workflows-buildbuddy-executor   1/1

kubectl exec -n buildbuddy <workflow-pod> -- printenv | grep -i pool
#   MY_POOL=workflows

kubectl logs -n buildbuddy -l app.kubernetes.io/instance=buildbuddy-workflows --tail=200 \
  | grep "Initialized task scheduler"
#   CPU: 0 of 16,000 milliCPU allocated, Memory: 0 of 58,719,476,736 bytes allocated
```

`MY_POOL` is the variable the chart renders top-level `poolName` into; that is how you know
the key was not silently ignored. Empty output means it was, in which case this pod joined the
default pool and is now accepting build actions — the workflow would fail with `no registered
executors in pool "workflows"` while a 56Gi executor quietly competed with the build fleet.

The scheduler line is the second half, because the right pool at the wrong size fails the same
way. Memory is `limits.memory` minus a flat 10 GB; CPU is `limits.cpu` unreduced. Both must
clear what `resource_requests` in `buildbuddy.yaml` asks for.

## Cache proxy

A **third** release in this namespace, from a different chart:

| release | chart | values | deploy | hostPath cache |
|---|---|---|---|---|
| `bb-cache-proxy` | `buildbuddy-enterprise-cache-proxy` | `values-cache.yaml` | `./deploy-cache.sh` | `/var/lib/buildbuddy/cache-proxy` |

### What it is for

The backing cache is BuildBuddy Cloud, in GCP; the executors are in this datacenter. So every
cache read crosses the WAN, and each executor keeps a *private* filecache — a hit on one node
does nothing for the other two. The proxy is a read-through/write-through gRPC cache that is
**shared**, replacing three private caches with one warm cache on the LAN. Reads become local
on a hit; writes still go upstream, because the scheduler and the results UI read from the
canonical cache.

This is also why it does not hit the split-CAS problem that rules out a standalone cache like
`bazel-remote`. A proxy is not a separate store — a miss forwards upstream, so a digest
resolves no matter which side asks for it. See the note above `--host_platform` in `//.bazelrc`
for the general shape of that failure.

### Deploying

```bash
export KUBECONFIG=~/.kube/carverauto-oidc.yaml
./deploy-cache.sh --dry-run    # renders only, applies nothing
./deploy-cache.sh
```

### Checking it

The chart makes a **StatefulSet**, not a Deployment, so `kubectl get deploy` shows nothing:

```bash
kubectl get statefulset,pods,svc -n buildbuddy -l app.kubernetes.io/instance=bb-cache-proxy

kubectl rollout status statefulset/bb-cache-proxy-buildbuddy-enterprise-cache-proxy \
  -n buildbuddy --timeout=10m

# The one thing worth verifying by hand: that it reads through to OUR instance.
kubectl get secret -n buildbuddy \
  bb-cache-proxy-buildbuddy-enterprise-cache-proxy-config \
  -o jsonpath='{.data.config\.yaml}' | base64 -d | grep -A2 cache_proxy
#   must show carverauto.buildbuddy.io, NOT remote.buildbuddy.io
```

That last check matters because the chart's default `cacheTarget` is
`grpcs://remote.buildbuddy.io` — BuildBuddy's *shared* cloud, a different instance from ours.
Pointed there the proxy comes up perfectly healthy and misses every single request. It is the
same instance-mismatch trap `values.yaml` warns about for the executor's `app_target`, and it
fails silently rather than loudly.

### Gotchas

- **The release name may not exceed 20 characters.** The chart derives a headless Service named
  `<release>-buildbuddy-enterprise-cache-proxy-headless`; the chart contributes 33 characters
  and the suffix 9, against Kubernetes' 63-character Service name limit. `buildbuddy-cache-proxy`
  (22) fails with `metadata.name: Invalid value: ... must be no more than 63 characters`, and it
  fails *after* helm has created the ServiceAccount, Role, PDB and Secret — so the release looks
  half-installed and needs `helm uninstall` before retrying. `deploy-cache.sh` now checks this
  before calling helm.
- **hostPath plus replicas needs anti-affinity.** Two proxy pods on one node would corrupt each
  other's pebble directory. `values-cache.yaml` pins one per node.
- **`cacheProxyDataVolumeHostPath` is not optional.** The chart defaults to an emptyDir, which
  destroys the whole cache on every pod restart. A cold shared cache is strictly worse than the
  per-node filecaches it replaces.
- **`config.cache.max_size_bytes` defaults to 10 GB**, which would evict constantly.
- **`distributed_cache.cluster_size` must match `replicas`.** It defaults to 1.

### Disk budget: three caches, one disk

Nodes are 589 GB with roughly 180 GB of non-cache baseline. All three BuildBuddy caches can
land on the same node, on three deliberately separate hostPaths:

| path | cap | owner |
|---|---|---|
| `/var/lib/buildbuddy/cache` | 100 GB | `buildbuddy`, 3 replicas |
| `/var/lib/buildbuddy/cache-workflows` | 50 GB | `buildbuddy-workflows`, 1 replica |
| `/var/lib/buildbuddy/cache-proxy` | 100 GB | `bb-cache-proxy`, 1 per node |

Worst case is whichever node hosts the workflow runner: ~430 GB used, ~160 GB free. Every other
node sits near ~380 GB. Both clear the kubelet DiskPressure threshold (10% free, ~530 GB used).

The build fleet's cache was cut 150 → 100 GB to make room, which is the right trade *only once
the proxy is serving*: a private per-node cache is worth much less with a shared LAN cache in
front of it. Do not apply that reduction before the proxy is healthy — on its own it is simply
33% less cache absorbing the same WAN misses.

### Routing traffic to it

Deploying the proxy changes nothing by itself; nothing points at it. Two separate steps, and
both executor fleets need doing:

1. **Executors** — set `config.executor.cache_target` in `values.yaml` *and*
   `values-workflows.yaml`, then redeploy each (`./deploy.sh`, and the hand-typed helm command
   in "Two fleets" above). Batch this with any `local_cache_size_bytes` change so you pay one
   cold start rather than two: every executor rollout mints fresh filecache UUIDs.
2. **Bazel clients** — `--remote_cache=grpc://192.168.6.86:1985` in `//.bazelrc` (already set on
   `build:remote_base` and, separately, on `build:el9`), plus
   `--remote_bytestream_uri_prefix=grpcs://carverauto.buildbuddy.io` so BES artifact links in
   the results UI still resolve. Leave `--remote_executor` alone: the scheduler stays on
   BuildBuddy Cloud, and that is what keeps the CAS consistent.

### The address, and why it is an IP

`192.168.6.86` is a MetalLB LoadBalancer IP from the `k3s-lan-pool`, pinned in
`values-cache.yaml`.

The first attempt used a ClusterIP, and it only worked from inside the cluster. `//.bazelrc`
names one cache endpoint for every consumer, and `*.svc.cluster.local` means nothing on a
workstation — a local `--config=ci` build died at once with
`UNAVAILABLE: Unable to resolve host bb-cache-proxy-...svc.cluster.local`. A LAN LoadBalancer
IP is reachable from pods *and* from a Mac on the VPN, and being an IP it needs no DNS at all,
which also removes the question of whether cluster DNS reaches inside a workflow runner's
isolated environment.

Both MetalLB annotations are load-bearing. The cluster has two auto-assigning pools —
`k3s-lan-pool` (192.168.6.80-95) and `k3s-pool` (23.138.124.x, **public**) — so a bare
`type: LoadBalancer` is a coin flip that can put the build cache on a public address.
`address-pool` pins the pool, `loadBalancerIPs` pins the address, because `//.bazelrc`
hardcodes it and a reassignment would break every build until someone noticed.

If you ever need to move it, check what is free first:

```bash
kubectl get svc -A --field-selector spec.type=LoadBalancer \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IP:.status.loadBalancer.ingress[0].ip' \
  --no-headers | grep '192\.168\.6\.' | sort -t. -k4 -n
```

`grpc://`, not `grpcs://`: the chart runs with `ssl.enable_ssl: false` and publishes only the
plaintext ports. Note this means cache traffic crosses the LAN unencrypted — acceptable inside
the datacenter and over the VPN, but it is a reason not to move this onto `k3s-pool`.

## Workflows (`buildbuddy.yaml`)

The repo-root `buildbuddy.yaml` drives CI. Four things about it are easy to get wrong.

### `steps`, not `bazel_commands`

`bazel_commands` is a legacy field and no longer in the documented schema; it still parses.
`steps` takes **bash** commands rather than bazel subcommands, which matters for the
integration tier: `set -a; . "$FIXTURE_ENV"; set +a` must run in the *same shell* as the
bazel calls that consume it, so those belong in one multi-line `- run: |` step. Separate
steps do not share an environment.

### RBE is not on by default

BuildBuddy supplies `--bes_backend`, `--bes_results_url` and the API key header to every
invocation, but *not* remote cache or remote execution — "the configuration steps are the
same as when running Bazel locally." `--config=remote` is what enables them. Note that
`.bazelrc.remote` (which carries `--remote_header=x-buildbuddy-api-key=...`) is gitignored
and absent in CI; BuildBuddy injects the key itself, so this is fine.

### `self_hosted: true` requires a matching `pool`

Every executor here is self-hosted, so the runner should be too. But `self_hosted` defaults
the workflow pool to the name `workflows`, and `values.yaml` sets **no** `poolName` — these
executors are in the unnamed default pool. Without a matching `pool` the run fails with:

```
No registered executors in pool "workflows" with os "linux" with arch "amd64"
```

`pool: ""` does **not** fix this: an empty string reads as *unset*, so it falls straight back
to `workflows`. BuildBuddy's default pool name is literally the empty string, and there is no
way to spell that in the action YAML.

**RESOLVED, and not the way this section originally guessed.** We briefly set `pool: "default"`,
betting the app's `default_pool_name` was `default`. That bet was *correct* — the scheduler
resolved it to the unnamed default pool — but it did not matter, because the next failure was
a different one wearing similar words:

```
no registered executors in pool "" with os "linux" with arch "amd64" can fit a task
with milli_cpu=3000, memory_bytes=25769803776
```

Read the two apart carefully, because they are diagnosed completely differently:

| message | meaning |
|---|---|
| `No registered executors in pool "X"` | the pool name is wrong or that fleet is not deployed |
| `... in pool "X" ... **can fit** a task with ...` | the pool was found; no member is large enough |

The second is a sizing problem, and `25769803776` is exactly 24 GiB — the action's
`resource_requests`.

**The ceiling is `limits` minus a flat 10 GB, not `requests`.** Read it off the executor's own
startup line rather than inferring it:

```bash
kubectl logs -n buildbuddy <pod> | grep "Initialized task scheduler"
#   CPU: 0 of 16,000 milliCPU allocated, Memory: 0 of 58,719,476,736 bytes allocated
```

| fleet | `limits.memory` | advertised (limits − 10e9) | largest task |
|---|---|---|---|
| build | 32Gi = 34,359,738,368 | 24,359,738,368 (22.7 GiB) | 22 GiB |
| workflows | 64Gi = 68,719,476,736 | 58,719,476,736 (54.7 GiB) | 54 GiB |

CPU is the limit unreduced: `limits.cpu: "16"` → 16,000 milliCPU. So a fleet can advertise
plenty of CPU while rejecting a task purely on memory, and the message names only the fit
failure, not which dimension missed.

Two consequences. `resource_requests` in `buildbuddy.yaml` is in **GiB** despite the `GB`
suffix — `"14GB"` produced a VM BuildBuddy described as "15.03GB total", which is 14 GiB in
decimal. And raising `requests` alone never helps task placement; raise `limits`, then re-read
the log line.

The runner genuinely needs ~32GB, so the fix was the second-deployment alternative rather than
a pool rename: `pool: "workflows"` in `buildbuddy.yaml` against the dedicated fleet in
`values-workflows.yaml`. See "Two fleets" above. `build/rbe/BUILD` is deliberately **not**
touched — it sets no `Pool`, so build actions keep going to the default pool.

If you ever do need to rename the *default* pool, the three files still have to land together:

| file | change |
|---|---|
| `k8s/buildbuddy/values.yaml` | top-level `poolName: <name>` (sibling of `image`/`replicas`, **not** under `config.executor`) |
| `build/rbe/BUILD` | add `"Pool": "<name>"` to `rbe_platform` `exec_properties` |
| `buildbuddy.yaml` | `pool: "<name>"` — only if you want workflows there too |

Naming the executors without naming the pool in `rbe_platform` sends every RBE request to a
pool with no executors, which breaks all remote builds, not just workflows.

To see what the executors actually register as:

```bash
kubectl exec -n buildbuddy <executor-pod> -- printenv | grep -i pool
```

The runner also competes with build actions for these same 3 executors and asks for
3 CPU / 8 GB by default. Add `resource_requests` to the action if it starves the fan-out.

### Where the runner runs decides what it can reach

This is not about fan-out — that works either way, because `--config=remote` names a public
endpoint a BuildBuddy-hosted runner can dispatch through (a cloud-runner build reached 29
concurrent actions).

It matters because **`no-remote-exec` targets execute on the runner, not on an executor**.
The DB lifecycle targets in the integration tier are `no-remote-exec`, and only an
in-cluster runner resolves `srql-fixture-rw.srql-fixtures.svc.cluster.local`. With
`self_hosted: false` those four fail while the 8 remote shards succeed, and the shards then
connect to databases that were never provisioned.

Full reachability matrix and the fixture-credential design: `openspec/notes/bazel-bb-ci.md`.
