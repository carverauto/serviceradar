## ADDED Requirements

### Requirement: Repository security review baseline
The repository SHALL maintain a risk-based security review baseline that identifies the trust-boundary directories requiring audit coverage before remediation work begins.

#### Scenario: Baseline review scope is defined
- **GIVEN** a repository-level security review is initiated
- **WHEN** the review baseline is created
- **THEN** it SHALL identify the primary audit scope directories
- **AND** it SHALL identify the secondary audit scope directories
- **AND** it SHALL group the scope by trust boundary such as authentication, authorization, token handling, onboarding/bootstrap, certificate issuance, plugin execution, database access, and deployment exposure

### Requirement: Primary audit scope coverage
The security review baseline SHALL require the primary audit pass to cover the highest-risk directories in the repository before remediation work begins.

#### Scenario: Primary scope directories are included
- **GIVEN** the baseline review inventory
- **WHEN** an operator or reviewer checks required primary coverage
- **THEN** the primary scope SHALL include:
- **AND** `elixir/web-ng/lib`
- **AND** `elixir/serviceradar_core/lib`
- **AND** `elixir/serviceradar_agent_gateway/lib`
- **AND** `elixir/serviceradar_core_elx/lib`
- **AND** `go/pkg/agent`
- **AND** `go/pkg/edgeonboarding`
- **AND** `go/pkg/grpc`
- **AND** `go/pkg/config/bootstrap`
- **AND** `rust/edge-onboarding`
- **AND** `rust/config-bootstrap`
- **AND** `helm/serviceradar`

### Requirement: Canonical findings artifact
The security review program SHALL produce a canonical findings artifact for each baseline review.

#### Scenario: Finding is recorded with required fields
- **GIVEN** a reviewer confirms a security issue during the audit
- **WHEN** the issue is entered into the review artifact
- **THEN** the artifact SHALL record severity
- **AND** affected directories or files
- **AND** exploit preconditions and impact
- **AND** remediation guidance
- **AND** a disposition status

### Requirement: Findings disposition
Each confirmed finding SHALL be dispositioned into tracked follow-up work or an explicitly accepted risk.

#### Scenario: Confirmed finding becomes tracked work
- **GIVEN** a finding recorded in the canonical review artifact
- **WHEN** the finding is triaged
- **THEN** it SHALL map to one of the following:
- **AND** a dedicated remediation OpenSpec change
- **AND** an update to an existing in-flight hardening change
- **AND** an explicitly documented accepted risk entry

#### Scenario: In-flight hardening overlap is preserved
- **GIVEN** a confirmed finding is already covered by an active hardening change
- **WHEN** the finding is dispositioned
- **THEN** the review artifact SHALL reference the existing change
- **AND** the finding SHALL NOT require a duplicate remediation change unless the existing scope is insufficient
