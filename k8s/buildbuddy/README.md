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

We set `pool: "default"`, betting that the app's `default_pool_name` is `default` — which is
the same bet `build/platforms/BUILD.bazel` already makes with `"Pool": "default"` on the
`rbe_linux_*` platforms. **If that bet is wrong**, the run fails with the identical message
naming pool `"default"`, and the fix is to make the name explicit on both sides:

| file | change |
|---|---|
| `k8s/buildbuddy/values.yaml` | top-level `poolName: <name>` (sibling of `image`/`replicas`, **not** under `config.executor`) |
| `build/rbe/BUILD` | add `"Pool": "<name>"` to `rbe_platform` `exec_properties` |
| `buildbuddy.yaml` | `pool: "<name>"` |

Those three must land **together** and the helm redeploy must happen. Naming the executors
without naming the pool in `rbe_platform` sends every RBE request to a pool with no
executors — that breaks all remote builds, not just workflows.

The alternative, if the runner competing with build actions becomes a problem, is a second
small executor deployment with `poolName: workflows` and no `pool` in the action.

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
