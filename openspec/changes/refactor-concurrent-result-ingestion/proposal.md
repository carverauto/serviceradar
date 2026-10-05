# Change: Isolate result ingestion behind bounded supervised queues

## Why
StatusHandler and ResultsRouter still perform database work from singleton
callbacks, coupling unrelated result classes and acknowledgement deadlines.
ResultsRouter also has a stale flush-timer race, and SyncIngestorQueue accepts
unbounded payloads and decodes them in its mailbox (#5195; #5210 items 2 and 5).

This revises the proposal merged in #5266 for explicit user review. It is a
proposal-only change: implementation SHALL NOT start until the user approves
this revised proposal. A documentation merge alone is not approval to code.

## What Changes
- Enable RetainedPluginLane admission by default for capability-retained plugin
  results, preserving the agent's existing durable-completion acknowledgement.
  Current staging already has a source-and-capability predicate; its configuration
  default remains false. Verify both atom/string inputs and unsupported sources
  instead of replacing the predicate with an unconditional true value.
- Move per-status ingestion, service-state writes, workload-identity persistence,
  add-on status ingestion, and endpoint-inventory preprocessing into bounded
  supervised workers. The two dispatchers perform no Repo/Ash work, including
  through helper calls or rollback branches.
- Preserve per-key ordering and independent capacity per result class. Bounds
  include admitted pending and in-flight items and bytes; ingress and task counts
  must also be bounded, not just an internal queue behind an unbounded mailbox.
- Preserve commit-confirmed acceptance for ack-required statuses. Reject overload
  promptly and return not-accepted on failure or deadline expiry. Coordinate the
  internal deadline and rollout with Agent B's gateway PushStatus deadline work.
- Fix the ResultsRouter flush timer with a current reference token and ignore
  stale ticks. Perform the actual batch writes outside the router.
- Add bounded, reply-bearing SyncIngestorQueue admission; decode in its worker,
  propagate rejection, and prevent incomplete snapshots from activating.
- Publish queue-depth, admission, execution, rejection, and timeout telemetry
  through JetStream's canonical metric envelope and EventWriter. Local telemetry
  and Prometheus may supplement this path; they do not replace it.

## Impact
- Affected specs: edge-architecture and ingestion-routing (existing pending
  ADDED requirements in this proposal, revised together).
- Related contract: harden-flow-attribution-pipeline; retained delivery remains
  durable-terminus-confirmed, including its existing terminal failure markers.
- Affected code: core status_handler.ex, results_router.ex, admission/*,
  inventory/sync_ingestor_queue.ex, endpoint inventory admission, workload
  identity and add-on status workers, coordinator supervision, telemetry.
- Agent B owns gateway deadline/error mapping. This proposal states the contract
  it relies on; implementation must reconcile the final shared deadline values
  before enabling the retained lane in a supported release pairing.
- #5196 command sharding and #5197 alert durable enqueue are separate root causes
  and separate implementation PRs, not hidden additions to this change.
- Close #5195 and #5210 only when the implementation lands with green RBE CI
  and the required synthetic load evidence. This docs PR closes neither issue.
