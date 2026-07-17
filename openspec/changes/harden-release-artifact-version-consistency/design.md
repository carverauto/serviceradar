## Context

ServiceRadar currently uses the same numeric namespace for product Git tags
(`vX.Y.Z`) and OCI Helm chart packages (`X.Y.Z`). The intended release path
updates `VERSION` and `Chart.yaml` together, then publishes from a release
tag. In practice, chart-only packages were published with new chart versions
while `VERSION`, application images, and Git releases remained at `1.4.15`.
Those immutable package versions now block a later product release from using
the same number.

## Goals / Non-Goals

### Goals

- Make a product version explainable and traceable to one immutable source.
- Detect occupied Git and OCI chart versions before a release branch is
  mutated or a publish job starts.
- Prevent manual workflow dispatch from publishing product artifacts from an
  untagged commit.
- Preserve the ability to release Helm configuration fixes promptly, but make
  those releases visible as product releases.

### Non-Goals

- Delete, retag, overwrite, or reinterpret existing OCI packages.
- Rewrite Git history or reuse an already published version.
- Automatically sync demo or production as part of this guard.
- Create a second, independent public chart-versioning scheme in this change.

## Decisions

### A product release has one version identity

For a product release `X.Y.Z`, the Git tag is `vX.Y.Z`, `VERSION` is `X.Y.Z`,
and Helm `version` and `appVersion` are both `X.Y.Z`. The release workflow
publishes the OCI chart `X.Y.Z` and image tags `vX.Y.Z` only after validating
those inputs. A Helm-only correction therefore receives a formal product
release and changelog entry instead of silently reserving a future product
number.

### The tag, not a dispatch input or HEAD, is the source of truth

Push and manual-dispatch paths resolve an already existing tag, check that its
commit is reachable from `origin/staging`, and check all source metadata at
that commit. Manual dispatch is a retry/control surface for a real tag, not a
way to manufacture a release identity from an arbitrary branch or commit.

### Occupancy checks fail closed before mutation and publication

The cut helper queries both the remote Git tag namespace and the OCI chart
repository. An existing chart tag, an existing Git tag, or an inability to
verify either source aborts the cut before any release metadata is written.
The workflow repeats the artifact-occupancy check immediately before chart
publication to close the time-of-check/time-of-use window.

### Publish authority is isolated

Only the protected signing workflow receives write credentials for the OCI
chart repository. Normal developer and CI paths may perform read-only
occupancy checks. The release runbook documents how an operator responds to a
pre-existing version: select a new version, update the changelog, and preserve
the existing artifact as an audit record.

## Risks / Trade-offs

- A configuration-only Helm correction now needs a formal product release.
  This is intentional: users can see exactly which ServiceRadar version
  introduced the configuration change.
- OCI availability becomes a preflight dependency. The check fails closed,
  which may delay a release during a registry outage but avoids an ambiguous
  partial publication.
- Existing orphaned package versions remain visible. Removing them would not
  reliably invalidate cached/digest-pinned clients and would destroy useful
  provenance.

## Migration Plan

1. Treat existing chart-only `1.4.16` through `1.4.18` packages as immutable
   historical artifacts and do not reuse their versions.
2. Record that product releases `v1.4.19` through `v1.4.22` were subsequently
   published; do not reinterpret or reuse the earlier chart-only versions.
3. Add source, metadata, and occupancy guards with regression tests before the
   next product release.
4. Restrict chart write credentials to the protected release environment and
   document the operator recovery procedure.
5. Verify a subsequent release and a manual retry both resolve the same tag
   and cannot publish a second chart version.
