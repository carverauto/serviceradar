## 1. Discovery & Design
- [ ] 1.1 Inventory internal health event producers (PublishStateChange, HealthTracker, heartbeats, gRPC health checks).
- [ ] 1.2 Identify internal consumers relying on NATS subjects for health/state events.
- [ ] 1.3 Define PubSub topic(s) and payload contract for internal health updates.

## 2. Core Behavior
- [ ] 2.1 Update HealthTracker to persist HealthEvents and broadcast PubSub for internal events.
- [ ] 2.2 Disable NATS publishing for internal health/state transitions (PublishStateChange + HealthTracker defaults).
- [ ] 2.3 Update EventPublisher/EventBatcher usage so internal health does not enqueue to NATS.

## 3. UI & Consumers
- [ ] 3.1 Update web-ng live views to subscribe to internal health PubSub events.
- [ ] 3.2 Ensure UI falls back to DB reads on reconnect or missed PubSub events.

## 4. Validation
- [ ] 4.1 Add tests for HealthEvent persistence and PubSub emission on state transitions.
- [ ] 4.2 Verify EventWriter still processes external NATS streams; internal health events absent from NATS.

## 5. Docs & Spec Updates
- [ ] 5.1 Update docs/config notes for internal health event flow (no NATS).
- [ ] 5.2 Run `openspec validate remove-nats-internal-events --strict`.
