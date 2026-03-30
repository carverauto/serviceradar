## Context
- Release artifact mirroring already validates the initial source URL, but the HTTP client still follows redirects automatically.
- Mirroring enforces a maximum artifact size only after the full response has been loaded into memory.
- Edge-site setup bundles are intended to be executed by operators, so any shell interpolation bug has a high blast radius.

## Goals
- Ensure every hop in the mirrored artifact fetch path is revalidated against the existing outbound policy.
- Bound memory use during artifact mirroring and abort downloads once the size limit is exceeded.
- Ensure generated shell-facing bundle content treats site names as data, not shell source.

## Non-Goals
- Changing the release manifest format.
- Changing edge-site naming rules or slug semantics.
- Refactoring unrelated datasvc upload behavior.

## Decisions

### Redirect handling must be explicit
Artifact mirroring will stop using automatic redirect following. Redirect responses will be handled manually, with each `Location` target normalized, revalidated through `ReleaseFetchPolicy`, and subject to the same bounded fetch path as the initial URL.

### Mirroring must stream with an early size cutoff
Artifact downloads will stream into a temporary file or bounded accumulator and stop as soon as the mirrored byte count exceeds `@max_artifact_bytes`. The object upload step will continue to use the validated byte payload after the bounded fetch completes.

### Shell content must be quoted centrally
The NATS leaf generator will use a shared shell-escaping helper for any operator-visible shell script content so future interpolations do not reintroduce command substitution bugs.

## Risks
- Manual redirect handling can expose edge cases in repository/object-storage providers that currently rely on implicit client behavior.
- Streaming downloads changes the mirroring control flow and needs coverage for oversize and redirect cases.
