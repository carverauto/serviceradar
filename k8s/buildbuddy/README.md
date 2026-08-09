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
profile (`ci`, `remote`) inherits.

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
     -t registry.carverauto.dev/serviceradar/rbe-executor:v1.0.24.3 \
     --push .
   ```
2. Bump the tag everywhere it is referenced for Bazel (`MODULE.bazel`, `MODULE.bazel.lock`, `BUILD.bazel`, `build/rbe/BUILD`, `build/platforms/BUILD.bazel`, `buildbuddy.yaml`, and `warmup_additional_images` in `k8s/buildbuddy/values.yaml`).
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

### 2. The Bazel client in CI

`--remote_cache`, via the `build:cache_proxy` config in `//.bazelrc`.

**It is deliberately not part of `build:ci`.** `make test` is `bazel test -c opt --config=ci
//...` and AGENTS.md tells every developer to run it before opening a PR — from a laptop, which
cannot resolve a ClusterIP. So `build:cache_proxy` is opt-in, and the in-cluster jobs opt in by
appending one line to the `.bazelrc.remote` they already generate for the API key:

```bash
printf 'build:ci --config=cache_proxy\n' >> .bazelrc.remote
```

One line covers every bazel call in the job — `buildbuddy.yaml` alone makes thirteen.
`wasm-plugins.yml` uses bare `build` instead of `build:ci` because it drives bazel through
`make` with no `--config`; `release.yml` needs both because it does both.

**This only works because the `try-import` lines sit at the bottom of `//.bazelrc`.** They used
to sit ~80 lines above `build:remote_base`, and an rc file can only override configs defined
before it — so the opt-in expanded first and `remote_base` overwrote `--remote_cache` right back
to the cloud endpoint, silently. If those imports ever drift back up the file, the proxy stops
being used with no error anywhere. Check the effective value rather than trusting the file:

```bash
bazel build --announce_rc --config=ci 2>&1 | grep 'config definition'
# the LAST --remote_cache wins; build:cache_proxy must appear after build:remote_base
```

Bazel prints `WARNING: option '--remote_cache' was expanded from both option '--config=ci' and
option '--config=ci'`. That warning is the mechanism working, not a misconfiguration.

### ⚠️ Re-check the ClusterIP after every proxy deploy

**`build:cache_proxy` in `//.bazelrc` hardcodes the proxy's ClusterIP.** This is a deploy-time
coupling between a helm release and a file in this repo, and nothing enforces it.

The two hops deliberately address the proxy differently, and neither form is wrong:

| hop | address | why |
|---|---|---|
| `executor.cache_target` (`values.yaml`, `values-workflows.yaml`) | Service **FQDN** | executors are pods, with a kube-dns `resolv.conf` |
| `build:cache_proxy` (`//.bazelrc`) | **ClusterIP literal** | CI runners route to the service CIDR but do **not** resolve cluster DNS |

The FQDN was tried first for the client hop and fails in CI:

```
ERROR: Executing genrule //build/packaging/nats:nats_rpm_version failed: Failed to query
remote execution capabilities: UNAVAILABLE: Unable to resolve host
bb-cache-proxy-buildbuddy-enterprise-cache-proxy.buildbuddy.svc.cluster.local
```

BuildBuddy's own docs say to point clients at the cluster IP for exactly this reason.

**A ClusterIP is stable for the life of the Service, not forever.** It survives `helm upgrade`
(including the `LoadBalancer` → `ClusterIP` change this release went through), but a
`helm uninstall` + `install`, or any delete/recreate of the Service, reallocates it. The chart
exposes no `service.clusterIP` value, so it cannot be pinned from `values-cache-proxy.yaml`.

After any `helm uninstall`/`install` of `bb-cache-proxy`, or if CI starts failing to reach the
cache, compare the two:

```bash
kubectl get svc -n buildbuddy bb-cache-proxy-buildbuddy-enterprise-cache-proxy \
  -o jsonpath='{.spec.clusterIP}{"\n"}'
grep '^build:cache_proxy --remote_cache=' ../../.bazelrc
```

They must name the same address. A stale value fails loudly naming the address it tried, so it
is self-diagnosing — but it fails *every* in-cluster CI job at once, so check it as part of the
deploy rather than discovering it from a red pipeline.

Distinguishing the two failure shapes matters:

- `Unable to resolve host ...` — a **name** is configured where an IP belongs.
- `UNAVAILABLE` / connection refused / timeout naming an **IP** — either the IP is stale (re-read
  it above) or the runner cannot route to the service CIDR at all. If routing is the problem, the
  answer is a MetalLB internal VIP, the pattern already used for `demo/cnpg-rw-internal-lb` — not
  a different name.

### Could the client hop use DNS instead?

Yes, and it is a one-line executor flag — but only for jobs that run **as BuildBuddy actions**,
and it buys a new dependency. The default DNS inside an action is a public resolver, which is why
`*.svc.cluster.local` fails:

| isolation | flag | default | for cluster DNS |
|---|---|---|---|
| `oci` (what both fleets set as `default_isolation_type`) | `executor.oci.dns` | `8.8.8.8` | `""` — mounts the **executor pod's** `/etc/resolv.conf`, i.e. kube-dns |
| `firecracker` | `executor.firecracker_vm_resolv_conf` | unset → goinit falls back to `8.8.8.8`, `8.8.4.4`, `1.1.1.1` | `/etc/resolv.conf` — read **once at executor startup** and passed into each VM |

Neither applies to a **Forgejo** runner, which is not a BuildBuddy action at all — that would
need the runner itself to carry a kube-dns `resolv.conf`, or to run as a pod.

**Weigh it before doing it.** Routing action DNS through CoreDNS means every lookup in every
action — including public ones, which CoreDNS then forwards — depends on CoreDNS being healthy,
and it still requires reaching the kube-dns ClusterIP, which is the same routing assumption the
literal IP already makes. The IP costs one grep at deploy time and has no runtime dependency.
Prefer it unless the Service is being recreated often enough that the coupling actually hurts.

`--remote_bytestream_uri_prefix=carverauto.buildbuddy.io` rides along in the same config and is
required, not decoration: Bazel writes `bytestream://` URIs into the build event stream using
the `--remote_cache` target, so without it the BES is handed URIs naming a host it cannot reach
and artifacts such as the timing profile silently fail to load in the UI.

### Security: the Service must stay `ClusterIP`

Per BuildBuddy support, the proxy **should not be exposed publicly** — point in-cluster clients
at its private endpoint instead, which is what both hops above do.

**This was not hypothetical.** The release was installed as `type: LoadBalancer` with MetalLB
annotations (`k3s-lan-pool`, `192.168.6.86`), MetalLB fulfilled the request, and for 2d18h the
proxy answered on `192.168.6.86:1985` — and on nodePort `31299` — across the LAN. The chart
serves **plaintext gRPC** on 1985 and only opens the TLS port when `service.externalGRPCSPort`
is set, which it is not. Fixed in `values-cache-proxy.yaml`, which pins `ClusterIP` and drops
the MetalLB annotations rather than leaving them inert next to a type someone may flip back.

Re-check after any upgrade — the chart default is `LoadBalancer`, so a `helm upgrade` that
loses this file silently re-exposes it:

```bash
kubectl get svc -n buildbuddy bb-cache-proxy-buildbuddy-enterprise-cache-proxy -o wide
# want: TYPE ClusterIP, EXTERNAL-IP <none>
```

Nothing was lost by the change: both consumers reach the proxy through the in-cluster Service
DNS name, which resolves identically for `ClusterIP`.

Authentication needs nothing extra at either hop: clients present the same
`x-buildbuddy-api-key` header they already send, and the proxy verifies it against the upstream
app (`auth.remote`, with `reparse_jwts: false`). The proxy's **own** upstream key is separate,
lives in the `buildbuddy-api-key` secret, and is injected with `--set` — see the header of
`values-cache-proxy.yaml`. It never crossed the exposed port (the proxy uses it outbound over
`grpcs`), so the exposure did not leak it.

### Three releases, one namespace

`values-cache-proxy.yaml` captures this release. Note it is a **different chart** from the two
executor fleets in **Two fleets** above, so the warnings there about matching release name to
`-f` apply with one addition: the proxy's API key is not in the file, so an upgrade that omits
`--set config.cache_proxy.api_key=...` leaves it unable to authenticate upstream.

Each of the three keeps its own hostPath — `/var/lib/buildbuddy/cache`, `cache-workflows`, and
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
