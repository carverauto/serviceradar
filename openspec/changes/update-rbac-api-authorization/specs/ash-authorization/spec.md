## ADDED Requirements

### Requirement: User-Initiated Requests MUST NOT Execute as SystemActor
For any HTTP request initiated by an authenticated user or API token, the system MUST execute Ash actions as that principal and MUST NOT substitute a system actor for authorization evaluation. SystemActor execution is reserved for internal/background operations and explicitly token-gated flows.

#### Scenario: Admin API executes as user actor, not system actor
- **GIVEN** a user makes a request to `GET /api/admin/collectors`
- **WHEN** the request is authorized
- **THEN** Ash reads are evaluated with the user actor (or equivalent service-account actor)
- **AND** the request MUST NOT be evaluated as a system actor

### Requirement: Context Modules MUST NOT Default to SystemActor for User-Facing Operations
Context modules used by controllers and LiveViews MUST require an explicit actor for user-facing operations. If a system actor is required, it MUST be explicitly opted into (for example by calling a dedicated internal function).

#### Scenario: OnboardingPackages.list requires explicit actor
- **GIVEN** a request to load edge onboarding packages in the admin UI
- **WHEN** the list operation is executed
- **THEN** the call includes an explicit user actor
- **AND** omission of actor MUST NOT result in implicit system-privileged access

### Requirement: Internal Scheduled Actions MUST NOT Use Unconditional Authorization
Scheduled/internal Ash actions MUST NOT be authorized by unconditional rules (for example `authorize_if always()`). They MUST use explicit internal authorization conditions (system actor role, or nil actor check intended for schedulers).

#### Scenario: Expire action cannot be invoked by a non-admin actor
- **GIVEN** a non-admin actor attempts to invoke an internal scheduled action (for example package expiration)
- **WHEN** the action is executed via Ash
- **THEN** the action is denied
- **AND** the action can only be executed by an explicit internal actor/check

