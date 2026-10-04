## ADDED Requirements

### Requirement: Stored Homepage Preference
The system MUST store a homepage as a kind and an optional target on the user and on the user group. The kind MUST be one of `platform`, `dashboards`, `authored`, or `package`, or null. `platform` and `dashboards` MUST store a null target. `authored` and `package` MUST store a target that matches `^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$`. A null user kind means inherit. A null group kind means that group sets no homepage. The system MUST reject a free-text URL and any other kind.

#### Scenario: Clear a user homepage
- **WHEN** a user clears the homepage on their profile
- **THEN** both stored fields for that user are null

#### Scenario: Reject a URL
- **WHEN** a homepage target contains a URL or a slash
- **THEN** the system rejects the save

### Requirement: Profile Homepage Control
The profile page MUST let the signed-in user choose the platform home, the dashboards list, one dashboard that user can open, or inherit. The specific-dashboard list MUST include only active authored dashboards and enabled packages that user can open, and MUST cap that list at 100.

#### Scenario: Save the dashboards list
- **WHEN** the user saves "Dashboards list" on `/settings/profile`
- **THEN** the user homepage kind is `dashboards` and the target is null

#### Scenario: Save one dashboard
- **WHEN** the user saves an active authored dashboard they can open
- **THEN** the user homepage kind is `authored` and the target is that dashboard id

### Requirement: User Group Homepage
A caller with `identity.user_groups.manage` MUST be able to set or clear a homepage on a user group from `/settings/user-groups`. The dashboard list MUST contain only dashboards that configuring caller can open. Saving a group homepage MUST NOT grant access to that dashboard.

#### Scenario: Group homepage does not share the dashboard
- **WHEN** a manager sets a group homepage to a dashboard
- **THEN** the group stores that dashboard id
- **AND** members who cannot open it do not gain access from that save

### Requirement: Homepage Precedence
After sign-in, when no return path was requested, the system MUST open the user's explicit homepage. When the user has none, it MUST open the homepage of the group whose membership `inserted_at` is newest. Equal assignment times MUST use the group name in ascending order. When no candidate applies, it MUST open `/dashboard`. An explicit `platform` choice MUST win over a group homepage. An identity-provider update of an existing membership MUST NOT change that membership's assignment time.

#### Scenario: User choice wins
- **GIVEN** a user whose homepage is the dashboards list and a group whose homepage is the platform home
- **WHEN** that user signs in with no return path
- **THEN** the session opens `/dashboards`

#### Scenario: Newest membership wins
- **GIVEN** a user with no homepage, a group named Zulu assigned earlier with the dashboards list, and a group named Alpha assigned later with an authored dashboard
- **WHEN** that user signs in with no return path
- **THEN** the session opens that authored dashboard

#### Scenario: Same assignment time uses the group name
- **GIVEN** a user with no homepage and two groups assigned at the same time, Alpha and Bravo, each with a homepage
- **WHEN** that user signs in with no return path
- **THEN** the session opens Alpha's homepage

### Requirement: Requested Page Wins
A non-blank return path MUST be used after the open-redirect check and MUST NOT be replaced by a homepage. An unsafe return path MUST resolve to `/dashboard` and MUST NOT consult the homepage.

#### Scenario: Deep link
- **WHEN** a user signs in while asking for `/devices/host01`
- **THEN** the session opens `/devices/host01`

#### Scenario: Unsafe return path
- **WHEN** a user signs in with a return path of `https://evil.example` or `//evil.example`
- **THEN** the session opens `/dashboard`
- **AND** the stored homepage is not consulted

### Requirement: Unavailable Homepage Falls Through
When a stored authored or package homepage is missing, unpublished, or not openable by the signing-in user, the system MUST try the next candidate and then `/dashboard`. Draft and archived authored dashboards are unpublished. A package homepage MUST be enabled. The sign-in info flash MUST include "Your saved homepage is no longer available, so this sign-in opened the next default." once when a stored choice was skipped. That notice MUST be appended to the existing signed-in message.

#### Scenario: Unauthorized dashboard
- **GIVEN** a user homepage that points at an authored dashboard the user cannot open, and a group homepage of the dashboards list
- **WHEN** that user signs in with no return path
- **THEN** the session opens `/dashboards`
- **AND** the info flash includes the unavailable-homepage notice

#### Scenario: Nothing stored
- **GIVEN** a user with no homepage and no group homepage
- **WHEN** that user signs in with no return path
- **THEN** the session opens `/dashboard`
- **AND** the unavailable-homepage notice is absent

### Requirement: SSO Membership Before Redirect
SSO sign-in MUST apply identity-provider group membership before choosing the homepage on that same request. SAML MUST pass a return path into login only when the pending request stored a non-empty path.

#### Scenario: New SSO user
- **WHEN** an identity provider signs in a user and maps them to a group that has a homepage
- **THEN** that sign-in uses the group homepage when the user has not set their own
