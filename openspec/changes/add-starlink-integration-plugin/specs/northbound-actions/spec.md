## ADDED Requirements

### Requirement: Multiple Named Credential Grants Per Invocation
The northbound dispatcher SHALL mint one scoped credential broker grant for each named
credential requirement an action declares, each resolved from its own credential rule, and
SHALL NOT allow an action input to retarget a grant to a different account or credential.

#### Scenario: Two-account action
- **WHEN** an action declares `source_account` and `destination_account` credential requirements
- **THEN** the invocation carries two grants, each resolved from the rule selected for that requirement

#### Scenario: Input attempts to retarget a grant
- **WHEN** action input values name an account or credential different from the resolved rules
- **THEN** the grants are unchanged and the plugin cannot use a token for the named account

### Requirement: Checkpointed Multi-Step Actions
A multi-step northbound action SHALL persist its progress in continuation state after every
completed step so that a resumed or retried invocation continues from the first incomplete
step.

#### Scenario: Agent restarts mid-flow
- **WHEN** the agent restarts after step two of a four-step action
- **THEN** the next poll resumes at step three and steps one and two are not repeated
