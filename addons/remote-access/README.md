# Remote Access Feature-Set Manifest

This directory is the native add-on contract reference for the compiled-in remote
access suite. It proves the framework can describe a legacy capability that remains
inside the base `serviceradar-agent` binary and is enabled by configuration, rather
than by a delivered sidecar artifact.

Remote access is not enrolled in `build/native_addons/addon_inventory.bzl` because
there is no native add-on binary to bundle for this reference shape. The current
implementation stays compiled in; the per-session RDP helper is the separate
`rdp` pushed-artifact / `ephemeral-helper` add-on under `addons/rdp-adapter`.

The manifest uses:

- `delivery: compiled-in`
- `supervision: config-toggle`
- `exec.binary: serviceradar-agent`

RDP sessions require both the compiled-in remote-access capability and the staged
`rdp` helper add-on. Keep them separate instead of turning this feature-set
manifest into a broad remote-access sidecar.
