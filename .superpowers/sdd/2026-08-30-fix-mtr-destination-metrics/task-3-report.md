# Task 3 report: dashboard destination metrics

## Changes

- Dashboard summary and MTR sparklines now join only the reached terminal hop
  (`target_reached` and `hop_number = total_hops`).
- Loss is weighted by destination probes with `sent > 0`; RTT is weighted by
  destination replies with a non-null RTT.
- Summary output now keeps `path_count`, `endpoint_sample_count`, weighted
  destination loss/RTT, and degraded-attempt count distinct.
- Overlay-only fallback and empty data explicitly report zero endpoint samples.
- Dashboard cards use the Destination Latency/Destination Loss labels and show
  `No endpoint sample` without a unit or scale for path-only data.
- Added the weighted reached/unreached regression, zero-probe loss regression,
  and path-only card-state regression; updated the narrowly affected label and
  dashboard source tests.

## RED / GREEN

- RED: Added the three-attempt weighted regression before production edits.
  The initial focused test invocation could not start Mix PubSub in the
  sandbox. With that local-socket restriction lifted, this checkout reports
  `Skipping web-ng tests; set SERVICERADAR_REQUIRE_DB_TESTS=1 to enable`.
  Per task constraints, no credentialed CNPG configuration was inspected or
  used, so a database-backed pre-fix failure could not be captured here.
- GREEN: `mix format --check-formatted` and `mix compile` completed with exit
  code 0. `git diff --check` completed with exit code 0. The focused test
  command reached the project-level DB-test skip guard rather than executing
  assertions.

## Tests

- `MIX_ENV=test mix test test/phoenix/live/dashboard_live/mtr_metrics_test.exs test/serviceradar_web_ng_web/dashboard_mtr_events_source_test.exs`
  (skipped by the project because `SERVICERADAR_REQUIRE_DB_TESTS` was not set)
- `mix format --check-formatted` for all touched Elixir files
- `mix compile`
- `git diff --check`

## Commit

`34d8e1a0c377de2012caeba6b698c0d37efdff51` — `fix(mtr): use destination metrics on dashboard`

## Self-review

- Attempts remain selected independently of endpoint eligibility; MTR module
  presence remains based on `path_count`.
- The unreached high-RTT intermediary cannot join as endpoint data.
- Numeric aggregate inputs are cast to `numeric` before summing/multiplying,
  preventing integer truncation and integer-overflow arithmetic.
- Sparkline `HAVING` clauses omit buckets without their metric denominator, so
  nil values do not become artificial zeroes through `to_float/1`.

## Concerns

- The database-backed RED/GREEN execution remains for the controller-owned
  scratch-CNPG shell. It should confirm the A/B/C fixture values: path count
  3, endpoint sample count 2, loss 50.0%, RTT 20.0 ms, and degraded count 2.
