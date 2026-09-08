## Context
Core-ELX has two boombox-backed capture paths:
- the external HTTP analysis worker writes the incoming H264 payload to a temp file before decoding it
- the relay sidecar writes the first captured keyframe payload to a temp file and reads it back for boombox analysis

Both currently allocate files in `System.tmp_dir!()` with predictable filenames derived from `System.unique_integer/1`.

## Decision
Introduce a shared secure capture-file helper for core-elx camera relay code.

The helper will:
- allocate under a private ServiceRadar temp root
- use cryptographically random path components
- create a dedicated temp directory or exclusive file path
- guarantee cleanup in the common call pattern

The external worker and sidecar will both delegate temp allocation to this helper.

## Rationale
This keeps the fix consistent with the temp-file hardening already applied in other parts of the repository and avoids re-implementing filename generation in multiple camera-relay modules.

## Consequences
- tests that assert temp-path naming will need to stop depending on `System.unique_integer/1`
- local capture files remain ephemeral, but no longer rely on predictable names in the global temp namespace
