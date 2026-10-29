# Explicit local camera spool initialization

The production core release includes
`ServiceRadarCoreElx.CameraRecording.SpoolInitializer.main/0`. Invoke it once
per intended volume, offline and under exclusive infrastructure ownership. It
creates only the `recordings` child of that volume and delegates durable marker
creation to `Storage.initialize/2`. Normal core startup never invokes it.

This command is the filesystem part of provisioning. Before invocation,
infrastructure must verify the UUID's association with the intended PVC UID,
PV UID and CSI volume handle, exclusive access, retention and encryption. The
command cannot prove physical-volume identity or exclusive mounting. A matching
marker is not that proof. The [read-only volume-association preflight](camera-spool-preflight.md)
checks retained identities and known consumers through the Kubernetes API; its
snapshot is not initialization authority or physical-volume qualification. The
exclusive Kubernetes Job, StatefulSet packaging and Cloud preservation workflow
remain separate implementation work.

## Inputs and invocation

Use the existing core runtime UID/GID and an already mounted, writable volume.
Supply only the volume and installation identity. Do not mount camera,
database, NATS, object-store or deployment-cookie credentials. Keep network
access and the service-account token disabled in the eventual provisioning Job.

- `VMS_SPOOL_VOLUME_ROOT`: an existing absolute, normalized directory path,
  2 through 4096 bytes. It must not be `/`, a final-component symlink, a relative
  path or a path with trailing separators or dot segments. Parent directories
  and mount ownership belong to trusted infrastructure.
- Identity: use either the explicit scalar
  `SERVICERADAR_CAMERA_RECORDING_STORAGE_ID` or the paired
  `SERVICERADAR_CAMERA_RECORDING_IDENTITY_FILE` and
  `SERVICERADAR_CAMERA_RECORDING_MEMBER`. The
  [member configuration contract](../openspec/changes/add-persistent-camera-spool/identity-configuration.md)
  owns the schema and ambiguity rules. The initializer requires a valid UUID
  even though ordinary disabled core startup permits an absent scalar.

The release carries `camera-spool-init.config`, an empty Erlang configuration
with no runtime config providers. Select it explicitly for `eval`; its path in
`RELEASE_SYS_CONFIG` omits the `.config` suffix. Do not use `start` or `rpc`.
The entry point refuses an already distributed VM or a started core application.
The [Mix release contract](https://hexdocs.pm/mix/Mix.Tasks.Release.html#environment-variables)
defines `eval`'s clean boot and these environment settings.

An entirely synthetic invocation from the release root is:

```sh
env RELEASE_SYS_CONFIG="$PWD/camera-spool-init" \
  RELEASE_DISTRIBUTION=none ENABLE_TLS_DIST=false \
  RELEASE_COOKIE=unused_spool_initializer_cookie \
  ERL_FLAGS='+S 2:2 +fnu' ERL_CRASH_DUMP=/dev/null \
  VMS_SPOOL_VOLUME_ROOT=/mnt/example-camera-volume \
  SERVICERADAR_CAMERA_RECORDING_IDENTITY_FILE=/etc/example-camera/members.json \
  SERVICERADAR_CAMERA_RECORDING_MEMBER=camera-core-0 \
  bin/serviceradar_core_elx eval \
  'ServiceRadarCoreElx.CameraRecording.SpoolInitializer.main()'
```

Ensure the scalar variable is absent for this member-mode invocation; `env`
does not erase inherited variables. Use a private writable temporary directory
for the release process, separate from the retained recording subdirectory.
The command needs no cluster cookie; the example value is a nonsecret placeholder
for a nondistributed process.

## Filesystem and result contract

Identity validation happens before directory creation. A missing `recordings`
child is created with mode `0700`. An existing child is never chmodded or chowned;
the storage owner verifies its type and private permissions. Filesystem
housekeeping at the volume root remains untouched. There is no recursive scan,
permission repair, deletion or fallback spool.

The [storage initialization contract](../openspec/changes/add-vms-storage-playback-engine/spool-lifetime.md#provision-once-verify-during-use)
owns marker durability, exact retries and refusal without repair.
After `Storage.initialize/2` succeeds, this command also fsyncs the volume
directory before reporting success so the new child entry is durable. A failed
operation can leave a newly created directory or partial marker; inspect and
reconcile it explicitly rather than deleting it or adding an automatic repair
loop.

The command prints one JSON result and exits:

- Exit `0`, `{"status":"initialized"}`: initialization or exact retry completed.
- Exit `1`, `{"status":"refused","reason":"..."}`: configuration, filesystem
  or runtime refusal. The bounded reason contains no paths, UUIDs or exception
  text. A process killed before it reports success is unresolved.

The provisioning controller must impose a finite execution deadline; a blocked
filesystem syscall cannot establish success. Preserve unresolved storage and
confirm process exit and unmount before starting its core member. Configure
`SERVICERADAR_CAMERA_RECORDING_SPOOL_ROOT` to the same volume's `recordings`
subdirectory and the same installed identity. Keep recording disabled until
its separate acceptance passes.

Success does not grant recording, upload or publication authority, qualify an
archive provider, attest a physical volume, or make recordings playable.

## Validation ownership

`//build/media:provider_probe_release_startup_test` invokes this command from
the declared production release archive, using its packaged configuration,
invented real filesystems and no service credentials or external network.
It covers member/scalar selection, new-root permissions, housekeeping, exact
retry, identity conflict, partial and nonempty spools, aliasing and invalid input.
The existing core-elx `SpoolTest` remains the owner of detailed marker durability,
replacement and worker-facing storage behavior. Kubernetes mount exclusivity,
pod replacement, retention and live capture remain deployment acceptance work.
