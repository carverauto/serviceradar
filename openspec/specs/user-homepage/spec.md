# user-homepage Specification

## Purpose
Resolution and configuration of user, group, and deployment default landing pages across authentication and dashboard navigation.

## Requirements

### Requirement: Typed Homepage Value
The system SHALL represent a homepage as a typed choice (`overview`, `dashboards_index`, or `dashboard` with an authored or package target) and SHALL derive the redirect path server-side, never storing or redirecting to a user-supplied URL.

#### Scenario: Unknown kind rejected
- **WHEN** a client submits a homepage with a kind outside the allowlist or a free-text path
- **THEN** the save is rejected with a validation error and no value is stored

#### Scenario: Dashboard target becomes a dashboard route
- **WHEN** a homepage of kind `dashboard` targets an authored dashboard
- **THEN** the resolved path is that dashboard's own route built by the server (`/dashboard/<ref>` for an authored dashboard, `/dashboards/<route_slug>` for a package instance)

### Requirement: Homepage Resolution Precedence
The system SHALL resolve the post-sign-in destination in the order: sanitized return path, user homepage, highest-ranked group homepage, deployment default homepage, then `/dashboard`.

#### Scenario: Deep link wins
- **WHEN** a user signs in with a sanitized `return_to` path and has a user homepage
- **THEN** the user is redirected to the return path

#### Scenario: User overrides group
- **WHEN** a user with their own homepage belongs to a group that has a different homepage
- **THEN** the user is redirected to their own homepage

#### Scenario: Group overrides deployment default
- **WHEN** a user without their own homepage belongs to a group with a homepage and a deployment default is set
- **THEN** the user is redirected to the group homepage

#### Scenario: Nothing configured
- **WHEN** no user, group, or deployment homepage applies
- **THEN** the user is redirected to `/dashboard`

#### Scenario: Root path uses the resolver
- **WHEN** an authenticated user requests `/`
- **THEN** the redirect target is the resolved homepage, not a fixed `/dashboard`

### Requirement: Redirect-Time Authorization
The system SHALL re-check, as the signing-in user, that a `dashboard` homepage target exists and is readable at redirect time, and SHALL fall through to the next precedence level when it is not.

#### Scenario: Deleted dashboard falls through
- **WHEN** a user's homepage dashboard has been deleted
- **THEN** the resolver skips it, the user lands on the next applicable level, and a one-time notice says the homepage is unavailable

#### Scenario: Lost access falls through silently for group homepages
- **WHEN** a group homepage dashboard is not readable by a member
- **THEN** that member falls through to the next level without a notice

### Requirement: Deterministic Group Selection
The system SHALL choose among a user's groups that have a readable homepage by lowest `homepage_priority`, then case-insensitive group name, then group id.

#### Scenario: Explicit priority decides
- **WHEN** a user is in group A (priority 10) and group B (priority 50), both with readable homepages
- **THEN** group A's homepage is used

#### Scenario: Name breaks a priority tie
- **WHEN** two groups with readable homepages share the same priority
- **THEN** the group whose name sorts first case-insensitively is used

#### Scenario: Unreadable group skipped before ranking
- **WHEN** the highest-priority group's homepage dashboard is unreadable by the user
- **THEN** the next-ranked group with a readable homepage is used

### Requirement: Homepage Configuration Permissions
The system SHALL allow users to set only their own homepage, SHALL require `identity.user_groups.manage` to set a group homepage or priority, SHALL require the authorization-settings manage permission to set the deployment default, and SHALL reject a `dashboard` target the saving actor cannot read.

#### Scenario: Non-manager cannot set a group homepage
- **WHEN** an actor without `identity.user_groups.manage` updates a group's homepage
- **THEN** the update is forbidden

#### Scenario: Unreadable target rejected at save
- **WHEN** an actor saves a homepage pointing at a dashboard they cannot read
- **THEN** the save is rejected

### Requirement: SSO Users Inherit Group Homepages
The system SHALL apply IdP-mapped group membership before computing the post-sign-in redirect, so that a user's first SSO sign-in lands on the homepage of a mapped group.

#### Scenario: First SSO sign-in through a mapped group
- **WHEN** a new user signs in via SSO with a claim mapped to a group that has a homepage
- **THEN** the same sign-in request redirects the user to that group's homepage

### Requirement: Single Per-User Default
The system SHALL treat the dashboards hub "Set as default" action and the profile homepage setting as the same per-user homepage value.

#### Scenario: Hub default sets the homepage
- **WHEN** a user marks a dashboard as default in the dashboards hub
- **THEN** their profile shows that dashboard as their homepage and their next sign-in lands on it
