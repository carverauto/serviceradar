## ADDED Requirements

### Requirement: Typed Dashboard Actions API
The dashboard SDK SHALL expose typed `actions.list` and `actions.invoke` APIs and React hooks
for launching northbound actions from a dashboard, available only when the dashboard
manifest declares the `actions.invoke` capability.

#### Scenario: List actions for a device
- **WHEN** a dashboard with `actions.invoke` lists actions for a device
- **THEN** it receives typed descriptors including input schema, safety classification and whether confirmation is required

#### Scenario: Capability missing
- **WHEN** a dashboard without `actions.invoke` calls the actions API
- **THEN** the SDK rejects the call with a capability error

### Requirement: Typed Dashboard Events API
The dashboard SDK SHALL expose a typed `events.subscribe` API and React hook, available only
when the dashboard manifest declares the `events.subscribe` capability.

#### Scenario: Subscribe to device events
- **WHEN** a dashboard subscribes to events for a set of devices
- **THEN** new matching events are delivered to the hook until the component unmounts

### Requirement: Dashboard Action Confirmation
The dashboard SDK SHALL provide a confirmation helper for actions that require
confirmation, and the host SHALL refuse a dashboard-launched invocation of such an action
unless it carries a confirmation bound to that action and those targets.

#### Scenario: Unconfirmed destructive action
- **WHEN** a dashboard invokes an action that requires confirmation without a matching confirmation
- **THEN** the host rejects the invocation and no command is dispatched to an agent

#### Scenario: Confirmation reused for other targets
- **WHEN** a confirmation issued for one target set is presented with a different target set
- **THEN** the host rejects the invocation
