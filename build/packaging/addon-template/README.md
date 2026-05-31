# `os-package` native add-on template

Scaffold for delivering a native agent add-on as an OS package (`.deb` / `.rpm`)
instead of (or in addition to) a signed `pushed-artifact` tarball. This is the
`delivery: os-package` half of the native add-on framework
(`openspec/changes/add-native-addon-delivery-models`, task 1.2).

> This directory is **inert scaffold**: it has no `BUILD.bazel` and no entry in
> `build/packaging/packages.bzl`, so nothing here is built or released. Copy it to
> `build/packaging/<your-addon>/`, rename the `example-addon` / `serviceradar-addon-example`
> tokens, and wire it up per the steps below. The shipping reference instance is
> [`build/packaging/bumblebee-scan`](../bumblebee-scan) (Bumblebee = `os-package`
> + `systemd-timer`).

## The contract

An `os-package` add-on is a deb/rpm that:

1. **Depends on `serviceradar-agent`** (`deb_depends` / `rpm_requires`) — the add-on
   is governed by the agent and is meaningless without it.
2. **Is dormant on install.** The package installs the binary, manifest, config, and
   any systemd unit(s), but the post-install script **does NOT enable or start**
   anything. The agent activates the add-on (flips config / enables the unit / launches
   the on-host binary as a go-plugin) only when the add-on is enabled for that agent in
   Edge Ops. Pre-remove stops + disables whatever may have been activated.
3. **Installs to the standard paths** so the agent can find the binary by the
   `exec.install_path` + `exec.binary` declared in its `addon.yaml`:

   | What | Path | Mode |
   |------|------|------|
   | binary | `/usr/local/lib/serviceradar/bin/serviceradar-<addon>` | `0755` |
   | manifest | `/usr/local/lib/serviceradar/addons/<addon-id>/addon.yaml` | `0644` |
   | config | `/etc/serviceradar/<addon>.json` | `0640` (`conffiles`) |
   | systemd unit(s) | `/lib/systemd/system/serviceradar-<addon>.{service,timer}` | `0644` |
   | state dirs | `/var/lib/serviceradar/<addon>/...` | per `addon.yaml` `state_dirs` |

The `addon.yaml` shipped here MUST match the one in `addons/<addon-id>/` that the
discovery index is built from (same `id`, `version`, `capabilities`, `exec.binary`),
so the on-host package is self-describing and verifiable against the catalog.

## Supervision models with `os-package` delivery

`delivery` is independent of `supervision`. The common pairings:

- **`systemd-timer`** (this template's default — the Bumblebee model): ship a
  `.service` (`Type=oneshot`) + `.timer`; the agent enables the timer on activation,
  and ingests the spool the service writes. See `systemd/`.
- **`systemd-service`** (long-lived): ship a single `.service` (drop the `.timer`,
  change the service `Type`, e.g. `notify`/`simple`); the agent enables it on
  activation. File capabilities (`requires.os_capabilities`) are applied by the
  root-owned `agent-updater`, never by the package or the add-on.
- **`agent-sidecar`** (go-plugin subprocess): ship **no** systemd unit. The agent
  launches the installed on-host binary as a HashiCorp go-plugin and supervises it.
  Keep the binary + manifest + config; delete `systemd/` and the unit `files[]` entries.

## How to instantiate

1. **Copy** this directory to `build/packaging/<your-addon>/` and rename every
   `example-addon` → `<your-addon>` and `serviceradar-addon-example` →
   `serviceradar-<your-addon>` (filenames + contents).
2. **Author `addon.yaml`** (here and in `addons/<addon-id>/`) with
   `delivery: os-package` and the real `id` / `version` / `capabilities` /
   `supervision` / `requires` / `exec`.
3. **Add a `PACKAGES` entry** to `build/packaging/packages.bzl` (snippet below).
4. **Add the `BUILD.bazel`** to `build/packaging/<your-addon>/` (snippet below). The
   release aggregates in `release_targets.bzl` pick up every `PACKAGES` key
   automatically — no extra registration — so the new `<your-addon>_deb` /
   `<your-addon>_rpm` targets are released once the entry exists.

### `packages.bzl` entry

```python
    "example-addon": {
        "package_name": "serviceradar-addon-example",
        "description": "Optional ServiceRadar Example native add-on (os-package delivery)",
        "maintainer": "Michael Freeman <mfreeman@carverauto.dev>",
        "architecture": "amd64",
        "section": "utils",
        "priority": "optional",
        # Governed by the agent; meaningless without it. systemd for the unit(s).
        "deb_depends": ["systemd", "serviceradar-agent"],
        "rpm_requires": ["systemd", "serviceradar-agent"],
        "files": [
            {
                "src": "//go/cmd/serviceradar-example-addon:serviceradar-example-addon",
                "dest": "/usr/local/lib/serviceradar/bin/serviceradar-addon-example",
                "mode": "0755",
            },
            {
                # Self-describing manifest; MUST match addons/example-addon/addon.yaml.
                "src": "addon.yaml",
                "dest": "/usr/local/lib/serviceradar/addons/example-addon/addon.yaml",
                "mode": "0644",
            },
            {
                "src": "config/serviceradar-addon-example.json",
                "dest": "/etc/serviceradar/serviceradar-addon-example.json",
                "mode": "0640",
                "rpm_filetag": "config(noreplace)",
            },
            # systemd-timer model: ship the unit(s) as plain files so they are
            # installed but NOT auto-enabled (the macro's `systemd:` key and the
            # `files[]` entries only install — enable/disable is postinst/prerm).
            {
                "src": "systemd/serviceradar-addon-example.service",
                "dest": "/lib/systemd/system/serviceradar-addon-example.service",
                "mode": "0644",
            },
            {
                "src": "systemd/serviceradar-addon-example.timer",
                "dest": "/lib/systemd/system/serviceradar-addon-example.timer",
                "mode": "0644",
            },
        ],
        "directories": [
            {"path": "/var/lib/serviceradar/example-addon", "mode": "0750", "owner": "root", "group": "serviceradar"},
            {"path": "/var/lib/serviceradar/example-addon/spool", "mode": "0750", "owner": "root", "group": "serviceradar"},
        ],
        "postinst": "scripts/postinstall.sh",
        "prerm": "scripts/preremove.sh",
        "conffiles": [
            "/etc/serviceradar/serviceradar-addon-example.json",
        ],
    },
```

### `BUILD.bazel`

```python
load("//build/packaging:package_rules.bzl", "serviceradar_package_from_config")
load("//build/packaging:packages.bzl", "PACKAGES")

package(default_visibility = ["//visibility:public"])

serviceradar_package_from_config(
    name = "example-addon",
    config = PACKAGES["example-addon"],
)
```

## Why dormant

The agent — not the package manager — owns add-on lifecycle. Enabling on install
would activate a capability on every host that happens to have the package, bypassing
Edge-Ops targeting/approval and the per-agent assignment. Keeping the unit installed
but disabled lets `apt`/`dnf` manage the bits while the agent's add-on dispatch decides
*when* a given agent runs it (`systemctl enable --now` for systemd models, or a
go-plugin launch for `agent-sidecar`).
