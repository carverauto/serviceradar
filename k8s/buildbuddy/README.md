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
else. The client side lives in `//.bazelrc`: `build:cache_only` owns cache/BES transport and
`build:remote_base` (therefore `ci`) inherits it.

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
      path: /mnt/buildbuddy/cache
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
- **Cache path**: `/cache` (hostPath `/mnt/buildbuddy/cache` on each node)
- **Remote builds dir**: `/cache/remotebuilds/`

### Node Affinity

None. `k8s-cp3-worker3` was excluded after the 2026-08-09 DiskPressure incident
(BuildBuddy hostPath on `/var/lib/buildbuddy` filling the OS disk). That cache
was purged and moved to `/mnt/buildbuddy`; kubelet DiskPressure on that node is
False. Re-adding a `NotIn` here strands a 1.2T cache disk. Keep caches off root.

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
- The host path (`/mnt/buildbuddy/cache`) is created per node and is not shared across nodes.
- **Must stay on `/mnt/buildbuddy` (dedicated ~1.2T disk).** Never use `/var/lib/buildbuddy` — that is on the OS root volume and previously caused node DiskPressure / pod evictions.
- After a Proxmox resize of the BB volume: `sudo xfs_growfs /mnt/buildbuddy` on each worker.
- If a node runs out of disk, grow `/mnt/buildbuddy` or adjust `local_cache_size_bytes` / cache-proxy `max_size_bytes`.

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
     -t registry.carverauto.dev/serviceradar/rbe-executor:v1.0.24.3 \
     --push .
   ```
2. Bump the tag everywhere it is referenced for Bazel (`MODULE.bazel`, `MODULE.bazel.lock`, `build/rbe/BUILD`, `buildbuddy.yaml`, and `warmup_additional_images` in `k8s/buildbuddy/values.yaml`). `build/platforms/BUILD.bazel` is no longer on this list: the two RBE platforms that pinned the tag there were dead and have been removed.
3. (Optional) If we ever choose to run a custom executor pod image, update `k8s/buildbuddy/values.yaml` and redeploy via `./k8s/buildbuddy/deploy.sh`.

Remote builds automatically use the refreshed Bazel action image as soon as the new tag is referenced in the Bazel exec platform configs—no Helm redeploy is required for that step.

## Two fleets

There are **two helm releases of the same chart** in this namespace, and they must not be
confused:

| release | values | pool | replicas | mem requests | hostPath cache | runs |
|---|---|---|---|---|---|---|
| `buildbuddy` | `values.yaml` | default (`""`) | 3, KEDA 3-10 | 16Gi | `/mnt/buildbuddy/cache` | build actions |
| `buildbuddy-workflows` | `values-workflows.yaml` | `workflows` | 1, unscaled | 56Gi | `/mnt/buildbuddy/cache-workflows` | the CI runner |

The workflow runner wants ~32GB — a Bazel server over ~2,000 targets, `--jobs=100` of input
uploads over the WAN, and database-facing TestRunner processes executing locally. Putting that on
the build fleet means either it cannot be placed (16Gi advertised) or, if you size the build fleet
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

## Workflows (`buildbuddy.yaml`)

The repo-root `buildbuddy.yaml` drives CI. Four things about it are easy to get wrong.

### `steps`, not `bazel_commands`

`bazel_commands` is a legacy field and no longer in the documented schema; it still parses.
`steps` takes **bash** commands rather than bazel subcommands, which matters for the
integration tier: `set -a; . "$FIXTURE_ENV"; set +a` must run in the *same shell* as the
bazel calls that consume it, so those belong in one multi-line `- run: |` step. Separate
steps do not share an environment.

### RBE is selected by the repository profile

BuildBuddy supplies the API key header to workflow invocations, but repository profiles still
own service and platform selection. `--config=ci` inherits `build:remote_base`, which adds the
Linux executor/platform and inherits cache/BES transport from `build:cache_only`. The ignored
`.bazelrc.remote` is absent in BuildBuddy workflows because the workflow runtime injects the key;
developer workstations use that file for the same credential header.

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

The workflow action uses the dedicated `workflows` fleet described above, not these three build
executors. Its current `resource_requests` live in `buildbuddy.yaml` (50GB memory / 40GB disk);
change those together with `values-workflows.yaml` when adjusting placement capacity.

### Where the runner runs decides what it can reach

This is not about fan-out. Compile actions can still use RBE/cache. It matters because every
database-facing **`TestRunner` action must execute on the runner that can resolve and reach
`srql-fixture-rw.srql-fixtures.svc.cluster.local`**. The integration workflow therefore uses
`--strategy=TestRunner=local` for the lifecycle tests and all eight shards. The prepare binary is
`bazel run`, so Bazel builds it under the selected profile and launches it on the runner. With a
cloud runner, lifecycle and shard actions all fail to reach the fixture rather than only the setup
steps failing.

Full reachability matrix and the fixture-credential design: `../../openspec/notes/archive/bazel-bb-ci.md`.

## Cache proxy

Three `bb-cache-proxy-buildbuddy-enterprise-cache-proxy-{0,1,2}` pods run the
[BuildBuddy Enterprise Cache Proxy](https://www.buildbuddy.io/docs/enterprise-proxy) chart in
this namespace. The proxy is a read/write-through cache in front of the BuildBuddy Cloud cache
at `carverauto.buildbuddy.io`: it serves what it already holds from inside the cluster and only
crosses the WAN for what it does not. Keeping that bulk traffic between our own servers is the
entire point of running it.

### The failure mode this section exists to prevent

**A cache proxy that nothing addresses is indistinguishable from a healthy one.** It registers
with the app, appears in the Cache Proxy tab, reports its version and uptime, passes its health
checks — and carries no traffic, because a proxy is never chosen automatically. Every client
has to name it. That is the state this cluster was in until the wiring below was added: three
proxies deployed, registered, visible in the UI, and idle.

There are exactly **two** hops to point at it, and they are independent — either works without
the other.

### 1. Executors (the bulk of the traffic)

`config.executor.cache_target` in both `values.yaml` and `values-workflows.yaml`.

This is the one that matters. Left unset it **defaults to `app_target`**, so cache traffic
follows the control plane out to BuildBuddy Cloud. Setting it splits the two: ByteStream, CAS,
ActionCache, Capabilities and the OCI fetcher move to the proxy, while scheduler registration,
task assignment and execution status stay on `app_target`. Across 3–10 executors at
`--jobs=100`, that is every action input read and every action output write.

`app_target` must keep naming the app — the proxy hosts no scheduler, so the two are not
interchangeable.

Deploy as usual (`./deploy.sh` for the build fleet; the workflow fleet is the hand-typed
`helm upgrade buildbuddy-workflows ... -f values-workflows.yaml`, see **Two fleets**), then
confirm the executor actually dialled it:

```bash
kubectl logs -n buildbuddy -l app.kubernetes.io/name=buildbuddy-executor --tail=200 \
  | grep 'Connecting to cache target'
# want: Connecting to cache target "grpc://bb-cache-proxy-...svc.cluster.local:1985"
```

### 2. Bazel clients through the public TLS edge (the default)

`build:cache_only` in `//.bazelrc` moves only `--remote_cache` to
`grpcs://cache-proxy.carverauto.dev:443`. That hostname terminates TLS on the shared Envoy
gateway and forwards HTTP/2 gRPC to the proxy's ClusterIP Service on port 1985. This is what
provides one authenticated route for developer laptops, Forgejo, cloud action namespaces, and
self-hosted workflows. The active self-hosted runner can reach the fixture ClusterIP, but it uses
the public cache endpoint for profile consistency; other clients cannot rely on service-CIDR
routing (see **Where the runner runs decides what it can reach**).

**There is nothing to opt into.** `--config=ci` inherits `remote_base`, so CI and
`make test` take the proxy path. A host-native integration run selects `build:cache_only`
directly, retaining the same cache/BES transport without selecting Linux RBE:

```bash
make build-workspace-cache    # bazel build -c opt --config=ci //...
make test                     # bazel test -c opt --config=ci //... (unit tiers)
bazel test -c opt --config=cache_only --config=database_env --strategy=TestRunner=local \
  --//build:enable_integration_tests --test_tag_filters= --nocache_test_results \
  //elixir/serviceradar_core:integration_tests_s0
```

The shard command assumes the matching disposable database was provisioned first. Follow the
explicit sweep/prepare/migrate/provision/test/teardown sequence in `AGENTS.md` or the
`srql-fixtures-db-tests` skill. There is no shell wrapper: Bazel does not order lifecycle targets
or guarantee a finalizer across invocations.

`make build-workspace-cache` and `make test-cache` still exist, but only as aliases that swap in
the CI flags — `BAZEL_CACHE_PROXY_CONFIG` in `//Makefile` is deliberately **empty**.

> **Do not write `--config=cache_proxy`.** Its transport settings now live in
> `build:cache_only`, inherited by `build:remote_base`; the old profile no longer exists. Bazel
> treats an undefined config as a hard error, not a warning:
>
> ```
> ERROR: Config value 'cache_proxy' is not defined in any .rc file   (exit 2)
> ```
>
> so a stale reference takes out an entire entrypoint rather than quietly skipping the proxy.
> `//buildbuddy_cache_proxy_config_test.py` asserts that every `--config` named by `//Makefile`
> or `//buildbuddy.yaml` is defined in `//.bazelrc`, precisely because this already happened
> once.

The routes are intentionally different:

| hop | endpoint | purpose |
|---|---|---|
| executor `cache_target` | `grpc://bb-cache-proxy-buildbuddy-enterprise-cache-proxy.buildbuddy.svc.cluster.local:1985` | bulk CAS/ActionCache traffic stays inside the cluster |
| Bazel `build:cache_only` `--remote_cache` | `grpcs://cache-proxy.carverauto.dev:443` | authenticated clients use public DNS and TLS |
| Bazel executor and BES | `grpcs://carverauto.buildbuddy.io` | scheduling and build-event services remain upstream |

The executors keep the in-cluster FQDN rather than the public edge, and that asymmetry is
deliberate: they are ordinary pods, so their traffic never leaves the cluster and never pays for
TLS termination at the gateway.

Do not point `--remote_executor`, `--bes_backend`, or `--bes_results_url` at the proxy. It hosts
none of those services, and the failure is silent rather than loud — the proxy is a BuildBuddy
server too, so it accepts the RPCs and the build simply stops appearing where anyone looks for
it. `--remote_bytestream_uri_prefix=carverauto.buildbuddy.io` is likewise required: Bazel derives
`bytestream://` artifact URIs from `--remote_cache`, while the BES and UI still fetch those
artifacts through the upstream BuildBuddy hostname. Get it wrong and builds still pass — only the
timing profile quietly fails to load.

Keep the `try-import` entries at the bottom of `//.bazelrc`. An rc file can only override
configs defined before it, so an override in `.bazelrc.remote` placed above `build:cache_only`
or `build:remote_base` is silently overwritten by them.

Measured on a full `//...` from a workstation: **~11 min direct, ~3-4 min through the proxy.**
The win is round-trip latency, not bandwidth — a `//...` build issues thousands of
`GetActionResult` and `FindMissingBlobs` calls, each costing a WAN RTT to BuildBuddy Cloud
against roughly a millisecond to the proxy. Reasoning about bytes predicts a small win and is
wrong by ~3x, because `--remote_download_minimal` already suppressed the byte volume.

### Authentication and transport boundary

The public listener is TLS-only. Envoy terminates TLS and routes gRPC; it does not replace or
duplicate BuildBuddy authentication. The cache proxy's native BuildBuddy authentication is the
authoritative access decision. Clients send their existing BuildBuddy credential, and the proxy
delegates remote authentication/JWT validation to the upstream BuildBuddy instance with JWT
reparsing disabled.

The client credential remains in BuildBuddy's runner configuration or the gitignored
`.bazelrc.remote`; it MUST NOT be committed to `.bazelrc`, the Makefile, workflow YAML, Helm
values, or the GitOps route. The proxy's own upstream key is separate, lives in the
`buildbuddy-cache-proxy-api-key` Kubernetes Secret, and is injected with `--set` as documented in
`values-cache-proxy.yaml`.

Do not use a TCP connect or an anonymous Capabilities response as proof of authorization:
Capabilities may be readable without a credential. A validation canary MUST execute a protected
ActionCache/CAS operation. Any real authenticated build — `make build-workspace` or
`bazel test -c opt --config=ci //...` — does that and is the preferred end-to-end check, since
both now route through the proxy by default.

### Staged rollout and rollback

1. Deploy the shared-gateway route, certificate reconciliation, DNS record, cross-namespace
   grant, and h2c edge Service from the GitOps repository. The Helm-managed proxy Service stays
   `ClusterIP`; no listener, LoadBalancer, or NodePort is added to it.
2. Confirm public DNS, certificate verification, and HTTP/2 ALPN before sending credentials:

   ```bash
   openssl s_client -connect cache-proxy.carverauto.dev:443 \
     -servername cache-proxy.carverauto.dev -alpn h2 </dev/null
   ```

3. With a local ignored `.bazelrc.remote` holding the credential header, run
   `make build-workspace-cache`, then `make test`. Confirm the BuildBuddy invocation and the
   cache-proxy hit/read/write metrics.
4. Run `bazel test //:buildbuddy_cache_proxy_config_test` to catch endpoint, bytestream-prefix,
   dangling-`--config`, or Make-alias drift.

**Rollback** is a one-line change of `build:cache_only --remote_cache` in `//.bazelrc` back to
`grpcs://carverauto.buildbuddy.io`. Because the proxy is now the default rather than an opt-in,
there is no per-job switch to flip: an edge outage affects every remote build until that line
changes, which is the trade accepted in exchange for nobody having to remember a flag.

Rollback is still client-first, because that one line is the only client-side dependency on the
public route. The executor fleet reaches the proxy over the internal ClusterIP path throughout
and is untouched by it, so the public GitOps route can be withdrawn after clients have reverted
without interrupting remote execution or its high-volume cache traffic.

The backend service itself must remain private after every chart upgrade:

```bash
kubectl get svc -n buildbuddy bb-cache-proxy-buildbuddy-enterprise-cache-proxy -o wide
# want: TYPE ClusterIP, EXTERNAL-IP <none>
```

### Three releases, one namespace

`values-cache-proxy.yaml` captures this release. Note it is a **different chart** from the two
executor fleets in **Two fleets** above, so the warnings there about matching release name to
`-f` apply with one addition: the proxy's API key is not in the file, so an upgrade that omits
`--set config.cache_proxy.api_key=...` leaves it unable to authenticate upstream.

Each of the three keeps its own hostPath — `/mnt/buildbuddy/cache`, `cache-workflows`, and
`cache-proxy` — for the reason `values-workflows.yaml` spells out: two caches sharing a
directory run two eviction loops that delete each other's entries while both believe they are
under budget. Their size budgets do stack on one disk, though; see the `max_size_bytes` note in
`values-cache-proxy.yaml` for the DiskPressure arithmetic before raising any of them.

### Measuring the split

`./podmonitor-cache-proxy.yaml` scrapes the proxies, because kube-prometheus-stack discovers
targets through CRDs and ignores the chart's `prometheus.io/scrape` annotations. The
hit/miss label is the local-vs-upstream split:

```promql
sum(rate(buildbuddy_proxy_byte_stream_read_bytes{cache_hit_miss_status="hit"}[1h]))
  / sum(rate(buildbuddy_proxy_byte_stream_read_bytes[1h]))
```

A near-zero denominator means nothing is addressing the proxy — recheck the two hops above
before looking anywhere else. Per-proxy summaries are also in the web UI's Cache Proxy tab.
