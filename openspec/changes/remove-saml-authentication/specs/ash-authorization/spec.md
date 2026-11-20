## MODIFIED Requirements

### Requirement: IdP Group Claims Map To Permission Sets
The system MUST allow an operator to bind an identity-provider group claim to a role profile, so
that a group grants a specific permission set rather than only one of the built-in roles.

#### Scenario: A group claim grants a custom profile
- **GIVEN** a role profile holding `plugins.stage` but not `plugins.approve`
- **AND** a mapping binding the IdP group `SR-Plugin-Authors` to that profile
- **WHEN** a user carrying that group claim signs in through OIDC
- **THEN** the user's role profile is set to that profile
- **AND** the user holds `plugins.stage`
- **AND** the user does not hold `plugins.approve`

#### Scenario: Existing role-only mappings keep working
- **GIVEN** a mapping that names a role and no profile
- **WHEN** a user matching it signs in
- **THEN** the user's role is set exactly as it was before this change
- **AND** no role profile is assigned by the mapping

#### Scenario: A mapping naming a deleted profile fails safe
- **GIVEN** a mapping referencing a role profile that no longer exists
- **WHEN** a user matching it signs in
- **THEN** the mapping does not grant that profile
- **AND** the condition is recorded so an operator can find it
- **AND** the sign-in does not grant more permissions than the remaining mappings allow
