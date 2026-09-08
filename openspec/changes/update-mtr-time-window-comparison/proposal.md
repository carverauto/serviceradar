# Change: Improve MTR time-window comparison

## Why
Operators want to compare MTR diagnostics across points in time, not only compare two individual traces. The current comparison page can answer "how did these two traces differ?" but it cannot answer "what changed today versus yesterday?" or "how does this selected incident window compare to the prior baseline?"

## What Changes
- Add first-party MTR time-window comparison modes:
  - trace-to-trace comparison for individual hop diffs
  - window-to-window aggregate comparison for today vs yesterday, last N hours vs previous N hours, and custom ranges
- Support partial-period comparisons by aligning windows by elapsed duration when the current period is incomplete.
- Add timeline-driven exploration so operators can select a range from recent retained history and drill into the traces behind summary changes.
- Add visual summaries for reachability, latency, loss, hop-depth, path-signature changes, and source-agent differences.
- Keep all comparison evidence drillable back to trace and hop rows.

## Impact
- Affected specs: `mtr-diagnostics`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/diagnostics_live/mtr_compare.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/diagnostics_live/mtr_data.ex`
  - `elixir/web-ng/assets/css/app.css`
  - focused web-ng MTR data/UI tests

