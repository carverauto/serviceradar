## ADDED Requirements

### Requirement: Job Management UI Requires Jobs Permission
The job scheduler UI and any actions that enqueue jobs (for example "Trigger Now") MUST be restricted to actors with permission `settings.jobs.manage`.

#### Scenario: User without permission cannot view job management UI
- **GIVEN** a logged-in user without `settings.jobs.manage`
- **WHEN** the user visits `/admin/jobs`
- **THEN** the system denies access (redirect or error)

#### Scenario: User without permission cannot trigger a job
- **GIVEN** a logged-in user without `settings.jobs.manage`
- **WHEN** the user attempts to trigger a job via `/admin/jobs/:id`
- **THEN** the system denies the action
- **AND** no job is enqueued

