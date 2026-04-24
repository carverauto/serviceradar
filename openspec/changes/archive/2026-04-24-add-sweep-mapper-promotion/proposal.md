# Change: Add Sweep-to-Mapper Promotion

## Why
Sweep groups can find live hosts that are not yet in inventory, but mapper discovery only runs from explicit mapper jobs or manual run-now actions. This leaves a gap where a subnet sweep can prove a host is reachable while SNMP-capable devices still never get promoted into mapper discovery for identity, interface, and topology enrichment.

## What Changes
- Add automatic promotion from sweep-discovered live hosts to on-demand mapper discovery when the host is an eligible SNMP candidate.
- Reuse existing mapper job assignment and command-bus delivery instead of creating a parallel discovery execution path.
- Record promotion decisions and suppression reasons so operators can trace why a sweep hit did or did not trigger mapper discovery.
- Keep promotion bounded and idempotent so repeated sweep hits do not spam mapper runs for the same host.

## Impact
- Affected specs: `sweep-jobs`, `network-discovery`
- Affected code: `elixir/serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex`, mapper job selection / command-bus integration, promotion telemetry/state tracking
