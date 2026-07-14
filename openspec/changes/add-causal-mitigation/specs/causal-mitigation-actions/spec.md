# causal-mitigation-actions Specification (delta for add-causal-mitigation)

This delta closes the actuation gap behind the authority layer. The `northbound_action_*`
framework (`automation/northbound/action_descriptor.ex`, `action_provider.ex`,
`dispatcher.ex`; tables `platform.northbound_action_descriptors` /
`northbound_action_providers`) ships today as a generic, provider-neutral dispatch/audit shell
with **no** block-flow, revoke-session, or quarantine actions and no provider that implements
them. This delta authors those descriptors and a registered provider so an `enforce`-mode
`auto_fire` (see `causal-mitigation-authority`) can actually dispatch.

## ADDED Requirements

### Requirement: Northbound Action Descriptors and Provider

This change SHALL author northbound `ActionDescriptor` records for `block-flow`,
`revoke-session`, and `quarantine` and register an `ActionProvider` that implements them,
because the `northbound_action_*` framework has no such actions today. Each descriptor SHALL be
authored through the existing descriptor upsert path with an `input_schema`,
`safety_classification`, `requires_confirmation`, `scopes`, and `credential_requirements`, and
the registered `ActionProvider` SHALL advertise the matching `approved_capabilities` and
implement those actions so the existing `Dispatcher` can invoke them end-to-end. The provider and descriptors SHALL reuse the existing invocation, audit, and
callback machinery — no redesign of the northbound framework contracts. An `enforce`-mode
`auto_fire` decision SHALL map the policy's `action_type`/`action_params` to a
`(provider_id, action_id, version)` descriptor plus invocation input and dispatch it through
this provider.

#### Scenario: Enforce-mode auto_fire dispatches a block-flow action through the new provider

- **GIVEN** the newly authored `block-flow` `ActionDescriptor` and its registered active `ActionProvider`
- **AND** an enabled `enforce`-mode rule with `authority='auto_fire'` and `action_type='block-flow'` whose blast radius is within `blast_radius_max`
- **WHEN** the policy engine actuates the decision for a matching verdict
- **THEN** it SHALL dispatch a `block-flow` action through the new provider via the existing `Dispatcher`
- **AND** the decision SHALL record `outcome='fired'` in `platform.mitigation_decisions`

#### Scenario: Descriptors are registered without redesigning the framework

- **WHEN** the `block-flow`, `revoke-session`, and `quarantine` descriptors are authored
- **THEN** they SHALL be created as `northbound_action_descriptors` rows under a registered `ActionProvider`
- **AND** the existing `ActionDescriptor` / `ActionProvider` / `Dispatcher` contracts SHALL be unchanged

#### Scenario: Dispatch failure is recorded, not silently dropped

- **GIVEN** an `enforce`-mode `auto_fire` decision that dispatches a `block-flow` action
- **WHEN** the northbound dispatch fails
- **THEN** the decision SHALL record `outcome='failed'` in `platform.mitigation_decisions`
- **AND** the failure SHALL NOT be recorded as `fired`
