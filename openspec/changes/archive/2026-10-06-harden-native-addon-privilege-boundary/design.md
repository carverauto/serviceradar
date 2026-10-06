## Context

The non-root agent downloads an add-on artifact, verifies its digest and optional
signature, extracts it below `/var/lib/serviceradar/agent/addons`, and switches a
`current` symlink. The setuid root updater later copies unit text from that tree,
applies file capabilities to its binary, and enables the unit. The installed
units execute the binary through the same agent-writable `current` path.

The verification and privileged use are separated by a writable filesystem
boundary. Digest and signature checks therefore establish transport integrity,
but do not establish the identity of the bytes that root later installs or
executes.

## Goals / Non-Goals

- Goals:
  - Make the bytes used by root come from one verified read of the signed
    artifact.
  - Ensure the executable, bundled data, and installed unit definitions are
    root-owned and not writable by the agent.
  - Keep configuration refresh and add-on rollback working without reinstalling
    the base agent package.
- Non-Goals:
  - Change agent-sidecar supervision or the Go plugin protocol.
  - Add a second signing key hierarchy.
  - Redesign individual add-on state and spool contracts.

## Decisions

### The updater verifies and materializes the privileged runtime

The agent retains the downloaded artifact as a non-executable staging input. For
a systemd-supervised assignment it passes the expected add-on identity, version,
binary name, SHA256, and Ed25519 signature to the updater. The updater opens the
artifact once, verifies that byte slice, extracts it into a temporary directory
below `/usr/lib/serviceradar/addons/<id>/versions`, fixes ownership and modes,
and atomically switches the root-owned `current` symlink.

This reuses the release verification key and archive validation already used by
the agent. The updater rejects missing signatures for privileged supervision.

### Units are installed only from the verified root-owned tree

Unit discovery may remain agent-side for orchestration, but the updater resolves
and reads every requested unit from its newly verified root-owned tree. It never
copies unit text or applies capabilities from `/var/lib/serviceradar/agent`.
Installed unit assets use `/usr/lib/serviceradar/addons/<id>/current` for
executables and immutable bundled data.

### Mutable configuration stays outside the executable tree

Assignment overlays are written below the existing per-add-on writable state
directory. Systemd unit assets reference that stable writable configuration path
when an add-on consumes assignment configuration. The root-owned artifact tree is
never made writable to accommodate configuration refresh, SELinux relabeling, or
spool output.

### Activation remains atomic across both trees

The agent's staged `current` symlink continues to identify the downloaded
candidate and support delivery retries. The updater owns a separate privileged
`current` symlink. It switches that link only after verification and extraction
succeed, and restores its previous target if unit installation or activation
fails. The agent records activation metadata only after the privileged install
completes.

## Risks / Trade-offs

- Existing hosts may have an updater too old to support secure materialization.
  The agent must detect the required flags and fail closed with an actionable
  upgrade error instead of using the writable execution path.
- SELinux labels must be applied inside the updater to the root-owned copy.
- Disk use temporarily includes the downloaded artifact, the agent extraction,
  and the privileged extraction. Retention must remove superseded trees without
  deleting an active rollback target.
- Add-ons that currently read configuration beside their binary need a unit-path
  migration to the writable state location.

## Migration Plan

1. Ship the updater interface and root-owned materialization path.
2. Change systemd add-on units to execute from the privileged runtime and read
   mutable configuration from the state tree.
3. Require the new updater flags before activating systemd-supervised add-ons.
4. On first successful activation, install the root-owned candidate and switch
   units atomically. Existing writable staging remains only as a delivery cache.
5. Remove obsolete executable relabel/write allowances from unit definitions.

Rollback restores the previous root-owned `current` target and reinstalls its
units. It never points a privileged unit back at the agent-writable tree.

## Open Questions

- Whether the agent-side extracted copy can be eliminated for systemd-only
  add-ons after compatibility with discovery and status reporting is proven.
