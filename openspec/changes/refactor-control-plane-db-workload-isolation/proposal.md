# Change: Refactor control-plane DB workload isolation

## Why
Recent Compose and demo investigations show a broader control-plane scaling flaw, not an MTR-only defect. The system currently allows background schedulers, Oban workers, maintenance jobs, and interactive control-plane workflows to compete for the same database budget inside `core-elx`. Under load, critical workflows such as MTR command/result persistence, agent heartbeat updates, analytics page reads, and operator actions can be delayed or starved by optional background work.

This is unacceptable for both small and large deployments. A one-node install with minimal data should remain nearly idle, and a larger deployment with hundreds or thousands of devices must continue to function with all major subsystems enabled. The fix must preserve full functionality rather than relying on feature disablement to stay stable.

## What Changes
- Define explicit workload-isolation requirements for database access so control-plane critical paths retain reserved DB capacity even when maintenance and enrichment jobs are active.
- Define scheduling and concurrency-governance requirements so background job throughput is sized against database budget rather than configured independently.
- Require the Docker Compose deployment profile to remain fully functional with major subsystems enabled, without disabling NetFlow, MTR, enrichment, or reconciliation work just to preserve usability.
- Add a technical design for repo/pool isolation, queue budgeting, workload classes, and observability needed to validate that scaling behavior.
- Establish acceptance criteria that cover interactive workflows under concurrent background load, including MTR dispatch/result persistence, agent heartbeats, and analytics page responsiveness.

## Impact
- Affected specs:
  - `job-scheduling`
  - `docker-compose-stack`
  - new capability `database-workload-isolation`
- Affected code:
  - `elixir/serviceradar_core/config/runtime.exs`
  - `elixir/serviceradar_core/lib/serviceradar/cluster/**`
  - `elixir/serviceradar_core/lib/serviceradar/agent_commands/**`
  - `elixir/serviceradar_core/lib/serviceradar/observability/**`
  - `elixir/web-ng/config/runtime.exs`
  - `docker-compose.yml`
  - runtime telemetry / test harnesses for load and concurrency validation
