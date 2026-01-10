## 1. Discovery & Design
- [x] 1.1 Inventory internal health event producers (PublishStateChange, HealthTracker, heartbeats, gRPC health checks).
- [x] 1.2 Identify internal consumers relying on NATS subjects for health/state events.
- [x] 1.3 Define per-tenant PubSub topic(s) and payload contract for internal health updates.

## 2. Core Behavior
- [x] 2.1 Update HealthTracker to persist HealthEvents, write OCSF events, and broadcast PubSub for internal events.
- [x] 2.2 Disable NATS publishing for internal health/state transitions (PublishStateChange + HealthTracker defaults).
- [x] 2.3 Update EventPublisher/EventBatcher usage so internal health does not enqueue to NATS.
- [x] 2.4 Add OCSF event resource mapping for `ocsf_events` (Ash + multitenancy).
- [x] 2.5 Emit OCSF events on Oban job failures for NATS account provisioning.
- [x] 2.6 Add sync ingestion state machine transitions and OCSF event writes for start/finish.
- [x] 2.7 Mirror edge onboarding events into OCSF for unified event stream.
- [x] 2.8 Retire legacy monitoring_events resource and drop the tenant table.

## 3. UI & Consumers
- [x] 3.1 Update web-ng live views to subscribe to internal health PubSub events.
- [x] 3.2 Update Events UI/SRQL mapping to read from `ocsf_events`.
- [x] 3.3 Ensure UI falls back to DB reads on reconnect or missed PubSub events.
- [x] 3.4 Subscribe Events UI to per-tenant OCSF event PubSub topics.

## 4. Validation
- [ ] 4.1 Add tests for HealthEvent persistence and PubSub emission on state transitions.
- [ ] 4.2 Verify EventWriter still processes external NATS streams; internal health events absent from NATS.

## 5. Docs & Spec Updates
- [ ] 5.1 Update docs/config notes for internal health event flow (no NATS).
- [ ] 5.2 Run `openspec validate remove-nats-internal-events --strict`.
