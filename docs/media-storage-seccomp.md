# Media storage io_uring seccomp profile

The media-storage chart defaults to `RuntimeDefault`. Operators running a
Longshore-enabled release can select a node-installed `Localhost` profile that
allows `io_uring_setup`, `io_uring_enter`, and `io_uring_register`. This setting
applies only to media-storage. It does not enable recording or select the storage
client; follow [archive storage installation](archive-init-storage.md) as well.

A Longshore client needs two things on each node, and the chart can apply
neither: the seccomp profile, and a locked-memory limit large enough for its
buffers. Both sections below are required.

## Prepare and distribute the profile

Use a reviewed OCI seccomp JSON profile derived from the container runtime's
default for the deployed runtime version, architecture, and dropped capabilities.
Preserve its default-deny action and existing syscall rules, and allow the three
io_uring calls. If the baseline explicitly denies those calls, resolve those rules
in the reviewed profile; simply appending an allow rule is insufficient. Do not
substitute an allow-all or audit-only profile.

The chart references the profile; node configuration management owns its content
and distribution. Kubernetes resolves `localhostProfile` below the kubelet's
seccomp directory, normally `/var/lib/kubelet/seccomp`. A ConfigMap mounted in the
application container does not install a profile there. Runtime defaults differ
by runtime and version; see the [Kubernetes seccomp guide](https://kubernetes.io/docs/tutorials/security/seccomp/).

Install the reviewed file on **every eligible node**, including replacement nodes,
before enabling the Helm setting. For a node using the default kubelet root,
these node-administrator commands install a versioned artifact:

```sh
sudo install -d -o root -g root -m 0755 /var/lib/kubelet/seccomp/serviceradar
sudo install -o root -g root -m 0644 media-storage-uring-v1.json /var/lib/kubelet/seccomp/serviceradar/media-storage-uring-v1.json
sha256sum /var/lib/kubelet/seccomp/serviceradar/media-storage-uring-v1.json
```

Compare the checksum with the reviewed artifact on each node. Use the actual
kubelet root if overridden. Keep the artifact and its runtime version/checksum
in infrastructure configuration management. A Security Profiles Operator already
installed in the cluster can distribute it instead; use the profile path that
operator reports. The ServiceRadar chart does not install a privileged node
writer or change the runtime's default for other workloads.

If only some nodes have the profile, label those nodes after installation and
add that label to `mediaStorage.nodeSelector`. Incorporate installation and
validation into node provisioning before applying the label to new nodes. Keep
the existing architecture selector unless the image supports another architecture.

## Select the installed profile

Merge this into the existing installation's values:

```yaml
mediaStorage:
  seccompProfile:
    type: Localhost
    localhostProfile: serviceradar/media-storage-uring-v1.json
```

The path is relative, with slash-separated components containing letters, digits,
underscores, hyphens, and dots. Components cannot begin with a dot. Absolute paths,
empty paths, dot/parent components, and `Unconfined` are rejected by the chart.
Helm cannot verify that a node has the file or that its contents allow io_uring.

Changing the profile path changes the pod template and triggers a rollout. Use a
new versioned filename for profile updates, install it everywhere first, and then
change the value. Replacing the JSON in place does not update running containers.
Keep older artifacts until no pods reference them. Revalidate after runtime or
kernel upgrades; a copied default does not inherit new runtime restrictions.

## Raise the locked-memory limit on the same nodes

Longshore registers its buffer pool with the kernel. That locks the pool in
memory and is what lets it send without copying. The kernel counts registered
buffers against the container's `RLIMIT_MEMLOCK`. A container inherits that limit
from the container runtime's service, commonly 8 MiB, and cannot raise it from
inside. With the limit too low the client fails at startup with an out-of-memory
error from buffer registration. There is no Longshore setting that avoids this.

Like the profile, this is node configuration that the chart cannot apply. Adding
the `IPC_LOCK` capability is not an alternative: the workload keeps all
capabilities dropped, and Pod Security `restricted` rejects it.

Raise the limit on the service that starts containers. Where that is a systemd
unit, use a drop-in. For a k3s agent:

```ini
# /etc/systemd/system/k3s-agent.service.d/10-memlock.conf
[Service]
LimitMEMLOCK=infinity
```

```sh
sudo systemctl daemon-reload
sudo systemctl restart k3s-agent
```

Use `containerd.service` or the distribution's equivalent where containerd runs
as its own service. Restarting a k3s agent leaves running containers in place,
but check what a restart does on your distribution before doing it. The limit
applies to every container the service starts afterwards. Containers that were
already running keep the old limit until their pod is recreated.

Apply it on **every eligible node**, including replacement nodes, and keep it in
the same configuration management as the profile. A node that has the profile but
not the limit will start the pod and then fail when the client starts. Use one
node label for both prerequisites and apply it only when both are in place.

Locked memory is counted per user ID on a node, so pods that run as the same UID
share one limit. A finite limit has to cover the client's whole buffer pool, which
is most of its memory. The pool is allocated at startup, so the pod's memory
limit must cover it as well.

Verify from inside the running pod:

```sh
kubectl -n example-monitoring exec deploy/serviceradar-media-storage -- sh -c 'ulimit -l'
```

The result must be `unlimited` or larger than the buffer pool, in KiB. A value of
`8192` means the node was not prepared or the pod predates the change.

## Verify before recording

Use the deployment's namespace in place of the synthetic `example-monitoring`:

```sh
kubectl -n example-monitoring rollout status deployment/serviceradar-media-storage --timeout=120s
kubectl -n example-monitoring get pods -l app=serviceradar-media-storage -o wide
kubectl -n example-monitoring get pods -l app=serviceradar-media-storage -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.securityContext.seccompProfile}{"\n"}{end}'
```

A failed rollout is a failed prerequisite. Inspect pod events for profile loading
errors, and check the scheduled node's artifact/path. A successful rollout only
proves startup: run the Longshore initialization and synthetic write/readback probe
in the same release and pod security settings on every eligible node. Record an
explicit pass/fail result; a ready pod alone does not prove ring creation works.
The workload must still run as UID/GID 10001, with all capabilities dropped,
privilege escalation disabled, and a read-only root filesystem.

Seccomp permission and the locked-memory limit are independent. Ring creation
can succeed and buffer registration still fail; see the next section.

Also verify the provider network path. Longshore currently lacks HTTP CONNECT
support; allowing io_uring does not make `mediaStorage.egressProxy` work with that
client. Keep provider egress restrictions in place and resolve proxy compatibility
before switching clients.

## Roll back

Stop recording activation and restore a release/client that works under
`RuntimeDefault` if necessary, then set:

```yaml
mediaStorage:
  seccompProfile:
    type: RuntimeDefault
    localhostProfile: ""
```

Wait for the rollout and check its result before removing unused node profiles.
Resetting seccomp alone does not make an io_uring-dependent client functional.
