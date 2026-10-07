## Context

Dashboard frame execution caps concurrency at 12 (`@max_frames` in
`FrameRunner`). `run/3` applies that cap with `Enum.take/2` twice: once before
`Task.async_stream`, and once when zipping results back to source frames.
Frames past the cap produce no map, no error, and no log.

The staleness fix stamped freshness on the frames that do run. It did not
change the cap. A bounded queue for in-flight refresh and page requests was
also left out; those requests already fail with `refresh_in_progress`.

## Goals / Non-Goals

- Goals: a declined frame is visible to the renderer as an error frame, and
  an author learns about the overflow when the manifest is checked.
- Non-Goals: coalescing in-flight channel requests, an `incomplete` frame
  status, re-running `required: false` frames, raising or removing the row
  cap, exposing `execute()`.

## Decisions

- Decision: keep `@max_frames` at 12 for this change. The defect is the silent
  drop, not the number.
- Decision: an overflow frame uses the existing error-frame shape and includes
  the source frame id, so the renderer can attach the failure to the manifest
  entry that was skipped.
- Alternatives considered: raising the cap, or running every declared frame.
  Both change host load. Reporting the decline does not.

## Risks / Trade-offs

- Packages that already declare more than 12 frames start showing errors for
  the tail. That is the point of the requirement. They render those frames
  today only by accident of omission.
- Manifest validation and the runtime cap can drift if they do not share one
  constant. Implementation should read `@max_frames` (or one shared value)
  from a single definition.

## Open Questions

- Where manifest validation should live. Confirm the checker before editing.
- Whether `incomplete` should exist for a frame whose query succeeded but was
  truncated by the row cap. Not specified here.
- Whether `required` and `refresh` should be separate manifest fields. Not
  specified here. The channel test that keeps optional frames cached without
  re-running them is the constraint.
