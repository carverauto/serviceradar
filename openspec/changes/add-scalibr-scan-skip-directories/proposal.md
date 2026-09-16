# Change: Add operator skip directories for ScaLibr endpoint inventory

## Why
The ScaLibr endpoint inventory scanner walks `scan_roots` (default `/`) and only skips `/proc`, `/sys`, `/dev`, and `/run`. On Kubernetes workers and build hosts that is a multi-million-inode walk through container snapshot layers and cache mounts, for OS package plugins that only need the host dpkg/rpm/apk databases. Operators already have a `dirs_to_skip` field, but it is easy to miss, the built-in default is too thin, and a delivered assignment list replaces the staged default instead of adding to it.

## What Changes
- Keep `dirs_to_skip` as the operator-facing skip list on the `scalibr-endpoint-inventory` add-on assignment and profile form.
- Always union that list with a built-in safety skip set inside the scanner so proc/sys/dev/run and common container/cache runtime trees cannot be dropped by a shallow config merge.
- Document skip semantics (absolute paths under a scan root; skipping a directory skips its descendants).
- Record the effective skip list on scan diagnostics so a noisy walk is visible without reading journal status lines.
- Expand package-default `dirs_to_skip` and schema copy so the form explains the field.

## Impact
- Affected specs: plugin-configuration-ui, scalibr-endpoint-inventory
- Affected code:
  - `addons/scalibr-endpoint-inventory/addon.yaml` (version bump)
  - `addons/scalibr-endpoint-inventory/config.schema.json`
  - `addons/scalibr-endpoint-inventory/scalibr-endpoint-inventory.json`
  - `go/pkg/scalibrinventory/` (built-in union, diagnostics)
  - add-on assignment/profile schema-driven form (copy only; string-list rendering already exists)
  - native add-on config contract fixtures if the delivered default document changes
- Out of scope: the hourly `server_reconcile_floor` full-scan loop, changing default `scan_roots`, language-ecosystem plugins, and glob-based skip patterns.
