# Change: Update sweep results push cadence + execution stats

## Why
Sweep results are currently pushed on a fixed cadence regardless of actual scan activity, which can cause excessive bandwidth usage and duplicate ingestion. Execution stats shown in the Active Scans UI are also incorrect (e.g., total hosts and availability counts), so operators cannot trust sweep progress.

## What Changes
- Gate sweep result pushes to actual scan activity (completion + optional progress batches).
- Define a configurable progress batch policy for large/long sweeps.
- Ensure core execution stats reflect the full sweep totals and availability counts.
- Surface accurate progress/status signals to the UI for active scans.

## Impact
- Affected specs: sweeper, sweep-jobs
- Affected code: agent sweep result emission, gateway forwarding, core sweep results ingestor, active scans UI stats
