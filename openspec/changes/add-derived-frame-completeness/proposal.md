# Change: Report dashboard frames the host declines to run

## Why

`FrameRunner.run/3` keeps the first `@max_frames` (12) data frames and drops the
rest with `Enum.take/2`. The dropped frames never become error frames, so a
manifest that declares a thirteenth frame renders as if that frame was never
declared.

`fix-dashboard-frame-staleness` (PR #4586, staging merge
`cfffd596900f170df8e64e77210fabe127d0b661`) shipped freshness stamps and left
this behavior out on purpose. Its spec delta had contained a scenario for it.
That scenario was removed before archive so the main spec would not require a
behavior the host does not implement. This change owns that scenario.

## What Changes

- When a manifest declares more data frames than the host will evaluate, each
  declined frame is delivered as an error frame carrying its id.
- Manifest validation reports the same overflow to the author before publish.
- The host still evaluates the frames it accepts.

## Impact

- Affected specs: `dashboard-sdk`
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng/dashboards/frame_runner.ex`
  (`@max_frames`, `Enum.take/2` in `run/3`). Manifest validation lands next to
  the existing dashboard manifest checker once that module is confirmed at
  implementation time.
- Non-goals, recorded so they are not lost with the staleness change:
  - A bounded coalescing queue for `frames:refresh` and `frames:page`. The
    channel already replies `refresh_in_progress` while a task is in flight.
  - An `"incomplete"` status. Freshness stamping still matches only
    `%{"status" => "error"}` on the stale-preservation path.
  - Splitting `required` from `refresh`. `required: false` frames are not
    re-run, and a named channel test asserts that.
  - Removing the per-frame row cap, and exposing `execute()`.

## Note

This is a proposal. Do not implement it until it is approved. The staleness
archive does not claim this behavior is shipped.
