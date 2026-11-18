# Change: Alert when an agent stops checking in

## Why

An agent that goes silent is marked `disconnected` after the stale-agent timeout
(`ServiceRadar.Infrastructure.StateMonitor`). Nothing turns that into an alert, for
three reasons:

- The transition is never recorded. Every agent, gateway and checker state-machine
  action carries `PublishStateChange`, which is meant to write a health event and the
  internal health log. Those actions are atomic, so Ash calls the change's `atomic/3`
  callback, which returned `:ok` and registered no hook. The `change/3` callback, where
  the hook lives, also read its keyword options as a map and raised. No agent
  `disconnected` or `connected` health event exists on an installation whose agent was
  offline for hours.
- The only seeded promotion for health logs matches `health.entity_type == "core"`
  (`ServiceRadar.Observability.RuleSeeder`), so an agent transition stays in the log
  table.
- The host device of a silent agent does not go `unavailable`. An agent check-in is
  evidence that the host is up and nothing else; when it expires the device is `unknown`,
  and a transition to `unknown` raises no availability event.
- A Kubernetes node going NotReady does alert, through its own seeded rule, which is why
  an operator hears about cluster nodes and not about edge agents.

An edge agent was offline for hours on one installation and no notification was sent.

One more defect sits behind these. A disconnected agent that checks in again is
marked `connected` by the `register_connected` upsert, which records no state change. An
alert opened on `disconnected` would therefore never clear.

## What Changes

- `PublishStateChange` runs on atomic actions and reads its options correctly, so the
  agent, gateway and checker transitions that declare it are recorded as health events.
- A seeded event rule promotes every agent health transition into a
  `health.agent.state_change` event.
- A seeded managed stateful rule, `agent_disconnected`, opens one critical incident per
  agent when it becomes `disconnected`, and recovers it when the agent becomes
  `connected`, `superseded` or `unavailable`.
- The check-in path records the `connected` transition of a returning agent, with the
  state the agent was in before.

Not in this change: alerts for gateways and checkers (their transitions are now recorded
but stay unpromoted), and any change to the stale-agent timeout.

## Impact

- Affected specs: `health-events`.
- Affected code: `ServiceRadar.Observability.RuleSeeder`,
  `ServiceRadar.Infrastructure.Agent` (`register_connected`),
  `ServiceRadar.Infrastructure.Changes.PublishStateChange`,
  `ServiceRadar.Edge.AgentGatewaySync`.
- Operator-visible: every installation gains an enabled critical alert for a
  disconnected agent. Agent, gateway and checker state transitions now appear on the
  health timeline, where before there were none; a newly registered agent writes one
  `connected` health event.
