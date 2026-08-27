## ADDED Requirements

### Requirement: Package dashboard visibility

Each `DashboardInstance` SHALL carry a `visibility` attribute constrained to `:private`, `:shared`,
or `:public`, and a nullable `owner_id` referencing the user who created the instance. `:public`
means every authenticated user may view the dashboard. `:shared` means the owner, holders of an
access grant, and holders of the administrative bypass permission may view it. `:private` means the
owner and holders of the administrative bypass permission may view it. The attribute SHALL be
enforced by an Ash read policy on `DashboardInstance`; it MUST NOT be interpreted independently by
any calling surface.

#### Scenario: Public instance is viewable by any authenticated user
- **GIVEN** an enabled dashboard instance with `visibility` of `:public`
- **WHEN** any authenticated user reads that instance
- **THEN** the read SHALL return the instance

#### Scenario: Private instance is owner-only
- **GIVEN** an enabled dashboard instance with `visibility` of `:private` and an `owner_id`
- **WHEN** a user who is neither the owner nor an administrative-bypass holder reads that instance
- **THEN** the read SHALL return no record

#### Scenario: Shared instance requires a grant
- **GIVEN** an enabled dashboard instance with `visibility` of `:shared` and no grant for the actor
- **WHEN** the actor reads that instance
- **THEN** the read SHALL return no record
- **AND WHEN** a `:view` grant naming the actor is created
- **THEN** a subsequent read SHALL return the instance

#### Scenario: Disabled instances remain unreachable regardless of visibility
- **GIVEN** a dashboard instance with `enabled` set to false and `visibility` of `:public`
- **WHEN** any user attempts to open its route
- **THEN** the system SHALL respond as it does for an unknown route

### Requirement: Package dashboard access grants

The system SHALL provide a `DashboardInstanceAccessGrant` resource granting `:view` or `:edit`
access on one `DashboardInstance` to either a single user or a single `Identity.UserGroup`. Grants
SHALL be unique per `(instance, subject_type, subject)` and SHALL be deleted when their instance or
their subject is deleted. Group grants SHALL resolve through `Identity.UserGroupMembership` at
evaluation time, so membership changes take effect without rewriting grants.

#### Scenario: Group grant follows membership
- **GIVEN** a `:view` grant on an instance naming a user group
- **AND** a user who is not a member of that group
- **WHEN** the user reads the instance
- **THEN** the read SHALL return no record
- **AND WHEN** the user is added to the group
- **THEN** a subsequent read SHALL return the instance

#### Scenario: Grant is removed with its instance
- **WHEN** a dashboard instance is deleted
- **THEN** every access grant referencing that instance SHALL be deleted

#### Scenario: Duplicate grant is an upsert
- **GIVEN** a `:view` grant on an instance for a user
- **WHEN** an `:edit` grant is created for the same instance and user
- **THEN** the system SHALL hold exactly one grant for that pair with access `:edit`

### Requirement: Shared grant-matching expression

The predicate that decides whether an access grant matches an actor SHALL exist in exactly one
module, used by both the authored-dashboard checks and the package-dashboard checks. A second
implementation of this predicate MUST NOT be introduced in either Elixir policy code or any calling
surface.

#### Scenario: Authored and package paths agree
- **GIVEN** an actor, a user group the actor belongs to, and an equivalent `:view` grant on an
  authored dashboard and on a dashboard instance
- **WHEN** both access checks are evaluated
- **THEN** both SHALL return the same decision

### Requirement: Route authorization for package dashboards

`GET /dashboards/:route_slug` SHALL resolve its instance through the authorized read. When the read
returns no record, the LiveView SHALL render a not-found state that does not disclose whether a
dashboard exists at that slug, and SHALL NOT emit the dashboard name, manifest, data frames,
renderer reference, or stream token to the client.

#### Scenario: Unauthorized viewer is denied without disclosure
- **GIVEN** a `:private` dashboard instance owned by another user
- **WHEN** an authenticated user opens `/dashboards/:route_slug` for it
- **THEN** the response SHALL be the same as for a slug that does not exist
- **AND** the rendered payload SHALL contain no stream token and no data-frame definitions

#### Scenario: Authorization is evaluated where the load happens
- **GIVEN** the dashboard is loaded asynchronously after the socket connects
- **WHEN** the asynchronous load runs
- **THEN** it SHALL use the authorized read under the connected user's scope
- **AND** an unauthorized result SHALL leave the socket in the not-found state

#### Scenario: Revocation takes effect on reload
- **GIVEN** a viewer with an active `:view` grant has the dashboard open
- **WHEN** the grant is revoked and the viewer reloads or renavigates to the route
- **THEN** the dashboard SHALL no longer render

### Requirement: Dashboard hub listing is authorization-filtered

The dashboard hub SHALL list only package-dashboard instances the current actor may view. An
instance the actor cannot view MUST NOT appear in the listing, in search results, or in any
placeholder or disabled row, because its name and route disclose the existence of a restricted
dashboard.

#### Scenario: Restricted dashboard is absent from the hub
- **GIVEN** an enabled `:private` instance owned by another user
- **WHEN** an authenticated user opens the dashboard hub
- **THEN** the listing SHALL NOT contain that instance under any presentation

#### Scenario: Administrative bypass sees everything
- **GIVEN** an actor holding the administrative bypass permission
- **WHEN** they open the dashboard hub
- **THEN** the listing SHALL contain every enabled instance

#### Scenario: Invisible default dashboard degrades gracefully
- **GIVEN** a user's default dashboard is an instance they can no longer view
- **WHEN** they land on their default dashboard
- **THEN** the system SHALL send them to the dashboard hub with an explanatory notice
- **AND** SHALL NOT raise an error page

### Requirement: Frame channel authorization and token binding

The dashboard frame channel SHALL bind its stream token to the user it was minted for and SHALL
re-derive the joining actor's current authority at join time rather than trusting cached session
permissions. A join SHALL be rejected when the token's user does not match the joining socket's
user, when the token's route slug does not match the topic, or when the joining actor cannot view
the instance.

#### Scenario: Token minted for one user is rejected for another
- **GIVEN** a stream token minted while user A viewed a dashboard
- **WHEN** user B presents that token on the same topic within the token's lifetime
- **THEN** the join SHALL be rejected
- **AND** no frame payload SHALL be pushed to user B

#### Scenario: Grant revoked mid-session cannot be ridden out
- **GIVEN** a viewer joined the channel with a valid token and grant
- **WHEN** the grant is revoked and the client rejoins with the still-unexpired token
- **THEN** the join SHALL be rejected

#### Scenario: Authority is re-derived, not read from the socket
- **GIVEN** a socket whose cached permission set still contains a since-revoked permission
- **WHEN** the client joins the frame channel
- **THEN** the authorization decision SHALL use freshly loaded authority
- **AND** the stale cached set MUST NOT be used as evidence

### Requirement: Renderer blob authorization

`GET /dashboard-packages/:id/renderer` and `/renderer.wasm` SHALL serve a package's renderer only
when the requester can view at least one enabled `DashboardInstance` backed by that package, in
addition to the existing checks that the package is enabled and verified. When no such instance is
viewable, the endpoint SHALL respond as it does for an unknown package.

#### Scenario: Renderer is withheld when no instance is viewable
- **GIVEN** a package whose only instance is `:private` and owned by another user
- **WHEN** an authenticated user requests that package's renderer by id
- **THEN** the response SHALL be a not-found response
- **AND** the renderer bytes SHALL NOT be transmitted

#### Scenario: Renderer is served through any one viewable instance
- **GIVEN** a package backing two instances, one `:private` to another user and one `:public`
- **WHEN** an authenticated user requests that package's renderer
- **THEN** the renderer SHALL be served

#### Scenario: Not-found and forbidden are distinguishable in the audit trail
- **WHEN** a renderer request is refused for authorization reasons
- **THEN** the recorded event SHALL distinguish an authorization refusal from a missing package

### Requirement: View access does not confer query override

Replacing a dashboard's declared frame query through request parameters SHALL require the viewer's
own analytics query permission. A viewer holding only a `:view` grant SHALL receive the frames
declared in the package manifest, and any supplied query override SHALL be ignored rather than
executed.

#### Scenario: View-only grantee cannot override a frame query
- **GIVEN** a viewer whose access comes solely from a `:view` grant and who lacks analytics query
  permission
- **WHEN** they open the dashboard route with a frame-query override parameter
- **THEN** the dashboard SHALL render the manifest's declared queries
- **AND** the override SHALL NOT be executed or signed into the stream token

#### Scenario: Query-permitted viewer keeps the override
- **GIVEN** a viewer who may view the dashboard and holds analytics query permission
- **WHEN** they supply a frame-query override
- **THEN** the override SHALL be applied as it is today

### Requirement: Publisher ownership of new instances

When a dashboard instance is created through the publish or enable API, the system SHALL record the
authenticated publisher as the instance's `owner_id`. Instances created by first-party seeding or by
a system actor SHALL be created with a null owner.

#### Scenario: CLI publish records the publisher
- **WHEN** an authenticated user publishes a package and enables it on a route
- **THEN** the created instance's `owner_id` SHALL be that user

#### Scenario: System-seeded instance has no owner
- **WHEN** a first-party dashboard is seeded at startup
- **THEN** the created instance's `owner_id` SHALL be null
- **AND** the instance SHALL still be reachable under the deployment's default visibility

### Requirement: Package dashboard sharing surface

The system SHALL provide a sharing control for a package dashboard that lets an authorized actor set
the instance's visibility and manage its user and group grants. The control SHALL be available to
the instance's owner and to holders of the package sharing permission, and SHALL be unavailable
otherwise. Browsing users and groups in the picker SHALL continue to require the existing share-
principals permission.

#### Scenario: Owner can share their dashboard
- **GIVEN** an actor who owns a dashboard instance
- **WHEN** they open the dashboard's sharing control
- **THEN** they SHALL be able to change its visibility and add or remove grants

#### Scenario: Unauthorized actor sees no sharing control
- **GIVEN** an actor who can view a dashboard but neither owns it nor holds the package sharing
  permission
- **WHEN** they open the dashboard
- **THEN** the sharing control SHALL be unavailable

#### Scenario: Picker respects share-principals permission
- **GIVEN** an authorized sharer who lacks permission to view share principals
- **WHEN** they open the sharing control
- **THEN** the user and group pickers SHALL be unavailable

### Requirement: Administrative bypass for package dashboards

The system SHALL provide a `dashboards.packages.view_all` permission that grants read access to
every package dashboard regardless of visibility or grants, defaulting to administrator roles only.
This permission SHALL bypass grant evaluation for reads and MUST NOT by itself confer edit, share,
publish, enable, or disable rights.

#### Scenario: Bypass holder opens a private dashboard
- **GIVEN** an actor holding `dashboards.packages.view_all`
- **WHEN** they open a `:private` instance owned by another user
- **THEN** the dashboard SHALL render

#### Scenario: Bypass does not confer sharing
- **GIVEN** an actor holding only `dashboards.packages.view_all`
- **WHEN** they open a dashboard they do not own
- **THEN** the sharing control SHALL be unavailable

### Requirement: Rollout preserves existing viewer access

The migration that introduces package dashboard access control SHALL set `visibility` to `:public`
on every `dashboard_instances` row that exists at migration time and SHALL leave their `owner_id`
null. No user who could open a dashboard before the upgrade may lose access to it as a result of the
upgrade. The migration SHALL verify the backfill by asserting that no pre-existing row remains at a
non-public visibility, and SHALL fail rather than complete silently if any does.

#### Scenario: Existing dashboards keep working after upgrade
- **GIVEN** a deployment with enabled dashboard instances and users who open them
- **WHEN** the deployment is upgraded to the release containing this change
- **THEN** every one of those users SHALL still be able to open every one of those dashboards

#### Scenario: Backfill is verified, not assumed
- **WHEN** the migration completes its backfill
- **THEN** it SHALL query for pre-existing rows whose visibility is not `:public`
- **AND** SHALL fail the migration if that query returns any row

#### Scenario: Rollback restores prior behaviour without a schema change
- **WHEN** the release is rolled back
- **THEN** package dashboards SHALL be reachable exactly as before the upgrade
- **AND** the added columns and grant table MAY remain in place

### Requirement: Default visibility for new instances is a deployment setting

The visibility applied to newly created dashboard instances SHALL be read from a deployment setting
`dashboards.packages.default_visibility`, whose shipped value SHALL be `public` in the release that
introduces this capability. Changing the shipped default to a restrictive value SHALL be a separate,
announced change and MUST NOT occur as a side effect of this one.

#### Scenario: Newly published dashboard is visible by default
- **GIVEN** a deployment on the shipped default
- **WHEN** a user publishes and enables a new dashboard
- **THEN** every authenticated user SHALL be able to open it

#### Scenario: Deployment opts into private-by-default
- **GIVEN** an administrator sets `dashboards.packages.default_visibility` to `private`
- **WHEN** a user publishes and enables a new dashboard
- **THEN** only that publisher and administrative-bypass holders SHALL be able to open it
- **AND** already-existing instances SHALL keep their current visibility

### Requirement: Visibility and grant changes are audited

Changes to a dashboard instance's visibility, owner, and access grants SHALL be recorded in the
append-only version history, capturing the acting user, the prior value, and the new value. The
audit record MUST NOT be able to reject the write it describes, and a grant that is revoked and
later restored SHALL leave both events in the history.

#### Scenario: Revocation and restoration both leave a trace
- **GIVEN** a `:view` grant is revoked and later re-created for the same subject
- **WHEN** the instance's history is inspected
- **THEN** both the revocation and the restoration SHALL appear, each with its acting user

#### Scenario: Visibility change records prior value
- **WHEN** an authorized actor changes an instance from `:public` to `:shared`
- **THEN** the history SHALL record the actor, the prior visibility, and the new visibility
