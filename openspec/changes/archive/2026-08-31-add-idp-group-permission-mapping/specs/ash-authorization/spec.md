## ADDED Requirements

### Requirement: IdP Group Claims Map To Permission Sets
The system MUST allow an operator to bind an identity-provider group claim to a role profile, so
that a group grants a specific permission set rather than only one of the built-in roles.

#### Scenario: A group claim grants a custom profile
- **GIVEN** a role profile holding `plugins.stage` but not `plugins.approve`
- **AND** a mapping binding the IdP group `SR-Plugin-Authors` to that profile
- **WHEN** a user carrying that group claim signs in through OIDC or SAML
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

### Requirement: Deterministic Resolution Of Multiple Matching Mappings
When several mappings match one sign-in, the system MUST resolve them deterministically and
independently of the order in which the mappings are stored.

#### Scenario: Permissions union across matched groups
- **GIVEN** a user carrying two group claims bound to two different role profiles
- **WHEN** the user signs in
- **THEN** the resulting permission set is the union of both profiles
- **AND** reordering the mappings does not change the outcome

#### Scenario: Highest matched role is applied
- **GIVEN** matching mappings that name different roles
- **WHEN** the user signs in
- **THEN** the highest-privilege matched role is applied

#### Scenario: No matching mapping falls back to the default
- **GIVEN** a user whose claims match no mapping
- **WHEN** the user signs in
- **THEN** the configured default role is applied
- **AND** the outcome is the same on every subsequent sign-in with the same claims

#### Scenario: Removal from a mapped group revokes what it granted
- **GIVEN** a user whose role profile was granted by an identity-provider mapping
- **WHEN** the user signs in and no mapping matches their claims
- **THEN** that role profile is revoked
- **AND** the configured default role is applied

#### Scenario: A manually assigned profile survives a no-match sign-in
- **GIVEN** a user whose role profile was assigned by an operator
- **AND** whose claims match no mapping
- **WHEN** the user signs in
- **THEN** the profile is retained
- **AND** revocation applies only to identity-provider-granted profiles

### Requirement: Operator Verification Of Claim Mappings
The system MUST let an operator determine why a mapping did or did not apply, without performing a
sign-in.

#### Scenario: Dry-run resolution of a claim set
- **GIVEN** an operator viewing the authorization settings
- **WHEN** the operator submits a sample claim set
- **THEN** the system reports which mappings matched, the resulting role, the resulting profile, and
  the resulting permission set

#### Scenario: Group mapping configured without the group scope is flagged
- **GIVEN** a mapping whose source is a group claim
- **AND** an OIDC configuration whose requested scopes do not include groups
- **WHEN** the operator views the authorization settings
- **THEN** the system warns that group claims will not arrive
- **AND** names the scope that is missing

#### Scenario: Last-login match is visible for a user
- **GIVEN** a user who has signed in through an identity provider
- **WHEN** an operator inspects that user
- **THEN** the system reports which mappings matched at that sign-in

### Requirement: IdP-Managed Group Membership
The system MUST support placing a user into a ServiceRadar user group from an identity-provider
group claim, and MUST distinguish those memberships from ones an operator created.

#### Scenario: Membership is created from a claim
- **GIVEN** a mapping binding an IdP group to a ServiceRadar user group
- **WHEN** a user carrying that claim signs in
- **THEN** the user becomes a member of that group
- **AND** the membership is marked as identity-provider managed

#### Scenario: Membership is withdrawn when the claim stops arriving
- **GIVEN** a user whose identity-provider-managed membership was created from a claim
- **WHEN** the user signs in without that claim
- **THEN** the membership is removed

#### Scenario: Operator-created membership is not removed
- **GIVEN** a user placed into a group by an operator
- **WHEN** that user signs in without a matching claim
- **THEN** the membership is retained
