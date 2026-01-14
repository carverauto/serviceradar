## Context
Sysmon disk collection currently uses an explicit include list (`disk_paths`), with defaults set to `["/"]`. In container environments the root filesystem can be an overlay mount, and operators often want to filter out Kubernetes/system mounts without losing visibility into other host volumes.

## Goals / Non-Goals
- Goals:
  - Collect all disks by default when no explicit include list is provided.
  - Provide an exclude list to filter out specific mount points.
  - Keep configuration backward compatible.
- Non-Goals:
  - Change the sysmon ingestion pipeline or payload shape beyond the config additions.
  - Introduce disk include/exclude pattern matching beyond explicit paths.

## Decisions
- Decision: Add `disk_exclude_paths` (array of strings) to sysmon config with a default of `[]`.
- Decision: Interpret `disk_paths: []` as “collect all disks,” then remove any mounts in `disk_exclude_paths`.
- Decision: Update the default sysmon profile to set `disk_paths: []` and `disk_exclude_paths: []`.

## Risks / Trade-offs
- Collecting all disks can increase payload size. Mitigate via configurable payload limits and explicit excludes.
- Backward compatibility: existing profiles with `disk_paths` set should remain unchanged; only empty list changes semantics.

## Migration Plan
- Add the new config field with default empty list.
- Backfill existing default profiles to use empty `disk_paths` and empty `disk_exclude_paths`.
- Roll out UI changes to expose exclude list controls.

## Open Questions
- Do we also allow excluding by filesystem type (e.g., tmpfs) or keep path-only for now?
