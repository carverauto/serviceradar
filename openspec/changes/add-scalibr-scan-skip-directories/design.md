## Context
`scalibr-endpoint-inventory` is a root systemd-timer add-on. It calls OSV ScaLibr's filesystem walker with `os/dpkg`, `os/rpm`, and `os/apk` extractors over `scan_roots` (default `/`). ScaLibr only extracts from the matching package databases, but it still visits every inode under the scan root unless `DirsToSkip` (or `PathsToExtract`) narrows the walk.

The config schema already exposes `dirs_to_skip`. On a Kubernetes worker with a large cache disk the delivered runtime config still skipped only `/proc`, `/sys`, `/dev`, and `/run`. The walker then spent ~13s at a full core visiting ~4.9 million inodes under containerd snapshots and cache mounts, and performed one extract. Inventory was correct (host OS packages); the host paid for a useless walk.

Two config-path details make this easy to get wrong:

1. Assignment `config_json` is shallow-merged over the staged base file. A delivered `dirs_to_skip` array **replaces** the staged default rather than appending to it.
2. `DefaultConfig()` in `go/pkg/scalibrinventory` does not fill `DirsToSkip` when the key is omitted. The ScaLibr CLI unions operator skips with `/dev`, `/proc`, `/sys`; the library adapter does not.

## Goals / Non-Goals
- Goals:
  - Operators can add host-specific skip directories on the add-on assignment or profile without editing JSON by hand.
  - The scanner always skips a built-in safety set even when the delivered list is empty or overwrites the staged default.
  - Scan diagnostics show the effective skip list actually used.
- Non-Goals:
  - Fixing cadence vs hourly timer vs `server_reconcile_floor` (separate defect; skip dirs do not depend on it).
  - Switching default `scan_roots` away from `/` or defaulting `paths_to_extract` to package-db paths.
  - Glob / basename skips (`**/.git`, all directories named `cache`). ScaLibr has `SkipDirGlob`; leave it unexposed unless a later change needs it.
  - Letting operators remove built-in safety skips.

## Decisions
- Decision: Operator field stays `dirs_to_skip` (string array of absolute paths). The assignment/profile form already renders `array` of `string`. Improve title/description; do not add a second field name.
- Decision: Union built-in skips with the operator list **in the scanner binary** immediately before `scalibrfilesystem.Run`. Do not rely on JSON merge or schema defaults for safety.
- Decision: Built-in set is the minimum of:
  - `/proc`, `/sys`, `/dev`, `/run`
  - `/tmp`, `/var/tmp`, `/var/cache`
  - `/var/lib/docker`, `/var/lib/containerd`, `/var/lib/rancher`, `/var/lib/kubelet`, `/var/lib/containers`, `/var/lib/buildah`, `/var/lib/buildbuddy`
  - `/var/lib/serviceradar/endpoint-inventory`
  Host-specific data mounts (for example a cache disk under `/mnt/...`) stay operator-configured. `/mnt` itself is not built-in.
- Decision: Skip matching follows ScaLibr: paths are absolute, must live under a scan root, are stripped to scan-root-relative keys, and skipping a directory skips its descendants. Unknown or out-of-root paths are ignored and recorded on diagnostics; they do not fail the scan.
- Decision: Scanner activity metadata `dirs_to_skip` SHALL be the **effective** union (built-in + operator, de-duplicated), not only the operator list.
- Alternatives considered:
  - Default `paths_to_extract` to package-db paths. Fastest walk, but would miss a later plugin that needs a broader tree and is a larger behavior change than requested.
  - Skip all of `/mnt` by default. Too broad; operators do keep software on data mounts.
  - Additive JSON merge for array fields. Would help this add-on and surprise every other array field. Binary-side union is local and explicit.

## Risks / Trade-offs
- Built-in `/var/lib/rancher` (and similar) means OS-package inventory will not pick up packages that exist only inside those trees. For the current `os/dpkg|rpm|apk` plugins that is intended; those databases live on the host.
- Operators who already shipped a full `dirs_to_skip` replacement keep their extras; they cannot unskip the built-in set. Document that.
- Native add-on version must bump because `config.schema.json` / default JSON / binary skip behavior change.

## Migration Plan
- Ship as `scalibr-endpoint-inventory` 0.1.7 (or next patch). Existing assignments keep working; extra operator paths remain additive.
- No data migration. Spool format unchanged.
- Rollback: previous add-on version restores the thin skip list.

## Open Questions
- None blocking. Glob skips can be a follow-up if operators need basename patterns.
