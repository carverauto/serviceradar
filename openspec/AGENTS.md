# OpenSpec Instructions

Instructions for AI coding assistants using OpenSpec for spec-driven development.

## TL;DR Quick Checklist

- Search existing work: `openspec spec list --long`, `openspec list` (use `rg` only for full-text search)
- Decide scope: new capability vs modify existing capability
- Pick a unique `change-id`: kebab-case, verb-led (`add-`, `update-`, `remove-`, `refactor-`)
- Scaffold: `proposal.md`, `tasks.md`, `design.md` (only if needed), and delta specs per affected capability
- Write deltas: use `## ADDED|MODIFIED|REMOVED|RENAMED Requirements`; include at least one `#### Scenario:` per requirement
- Validate: `openspec validate [change-id] --strict` and fix issues
- Request approval: Do not start implementation until proposal is approved

## Three-Stage Workflow

### Stage 1: Creating Changes
Create proposal when you need to:
- Add features or functionality
- Make breaking changes (API, schema)
- Change architecture or patterns  
- Optimize performance (changes behavior)
- Update security patterns

Triggers (examples):
- "Help me create a change proposal"
- "Help me plan a change"
- "Help me create a proposal"
- "I want to create a spec proposal"
- "I want to create a spec"

Loose matching guidance:
- Contains one of: `proposal`, `change`, `spec`
- With one of: `create`, `plan`, `make`, `start`, `help`

Skip proposal for:
- Bug fixes (restore intended behavior)
- Typos, formatting, comments
- Dependency updates (non-breaking)
- Configuration changes
- Tests for existing behavior

**Workflow**
1. Review `openspec/project.md`, `openspec list`, and `openspec list --specs` to understand current context.
2. Choose a unique verb-led `change-id` and scaffold `proposal.md`, `tasks.md`, optional `design.md`, and spec deltas under `openspec/changes/<id>/`.
3. Draft spec deltas using `## ADDED|MODIFIED|REMOVED Requirements` with at least one `#### Scenario:` per requirement.
4. Run `openspec validate <id> --strict` and resolve any issues before sharing the proposal.

### Stage 2: Implementing Changes
Track these steps as TODOs and complete them one by one.
1. **Read proposal.md** - Understand what's being built
2. **Read design.md** (if exists) - Review technical decisions
3. **Read tasks.md** - Get implementation checklist
4. **Implement tasks sequentially** - Complete in order
5. **Confirm completion** - Ensure every item in `tasks.md` is finished before updating statuses
6. **Update checklist** - After all work is done, set every task to `- [x]` so the list reflects reality
7. **Approval gate** - Do not start implementation until the proposal is reviewed and approved

### Stage 3: Archiving Changes
After deployment, create separate PR to:
- Move `changes/[name]/` → `changes/archive/YYYY-MM-DD-[name]/`
- Update `specs/` if capabilities changed
- Use `openspec archive <change-id> --skip-specs --yes` for tooling-only changes (always pass the change ID explicitly)
- Run `openspec validate --strict` to confirm the archived change passes checks

## Before Any Task

**Context Checklist:**
- [ ] Read relevant specs in `specs/[capability]/spec.md`
- [ ] Check pending changes in `changes/` for conflicts
- [ ] Read `openspec/project.md` for conventions
- [ ] Run `openspec list` to see active changes
- [ ] Run `openspec list --specs` to see existing capabilities

**Before Creating Specs:**
- Always check if capability already exists
- Prefer modifying existing specs over creating duplicates
- Use `openspec show [spec]` to review current state
- If request is ambiguous, ask 1–2 clarifying questions before scaffolding

### Search Guidance
- Enumerate specs: `openspec spec list --long` (or `--json` for scripts)
- Enumerate changes: `openspec list` (or `openspec change list --json` - deprecated but available)
- Show details:
  - Spec: `openspec show <spec-id> --type spec` (use `--json` for filters)
  - Change: `openspec show <change-id> --json --deltas-only`
- Full-text search (use ripgrep): `rg -n "Requirement:|Scenario:" openspec/specs`

## Quick Start

### CLI Commands

```bash
# Essential commands
openspec list                  # List active changes
openspec list --specs          # List specifications
openspec show [item]           # Display change or spec
openspec validate [item]       # Validate changes or specs
openspec archive <change-id> [--yes|-y]   # Archive after deployment (add --yes for non-interactive runs)

# Project management
openspec init [path]           # Initialize OpenSpec
openspec update [path]         # Update instruction files

# Interactive mode
openspec show                  # Prompts for selection
openspec validate              # Bulk validation mode

# Debugging
openspec show [change] --json --deltas-only
openspec validate [change] --strict
```

### Command Flags

- `--json` - Machine-readable output
- `--type change|spec` - Disambiguate items
- `--strict` - Comprehensive validation
- `--no-interactive` - Disable prompts
- `--skip-specs` - Archive without spec updates
- `--yes`/`-y` - Skip confirmation prompts (non-interactive archive)

## Directory Structure

```
openspec/
├── project.md              # Project conventions
├── specs/                  # Current truth - what IS built
│   └── [capability]/       # Single focused capability
│       ├── spec.md         # Requirements and scenarios
│       └── design.md       # Technical patterns
├── changes/                # Proposals - what SHOULD change
│   ├── [change-name]/
│   │   ├── proposal.md     # Why, what, impact
│   │   ├── tasks.md        # Implementation checklist
│   │   ├── design.md       # Technical decisions (optional; see criteria)
│   │   └── specs/          # Delta changes
│   │       └── [capability]/
│   │           └── spec.md # ADDED/MODIFIED/REMOVED
│   └── archive/            # Completed changes
```

## Creating Change Proposals

### Decision Tree

```
New request?
├─ Bug fix restoring spec behavior? → Fix directly
├─ Typo/format/comment? → Fix directly  
├─ New feature/capability? → Create proposal
├─ Breaking change? → Create proposal
├─ Architecture change? → Create proposal
└─ Unclear? → Create proposal (safer)
```

### Proposal Structure

1. **Create directory:** `changes/[change-id]/` (kebab-case, verb-led, unique)

2. **Write proposal.md:**
```markdown
# Change: [Brief description of change]

## Why
[1-2 sentences on problem/opportunity]

## What Changes
- [Bullet list of changes]
- [Mark breaking changes with **BREAKING**]

## Impact
- Affected specs: [list capabilities]
- Affected code: [key files/systems]
```

3. **Create spec deltas:** `specs/[capability]/spec.md`
```markdown
## ADDED Requirements
### Requirement: New Feature
The system SHALL provide...

#### Scenario: Success case
- **WHEN** user performs action
- **THEN** expected result

## MODIFIED Requirements
### Requirement: Existing Feature
[Complete modified requirement]

## REMOVED Requirements
### Requirement: Old Feature
**Reason**: [Why removing]
**Migration**: [How to handle]
```
If multiple capabilities are affected, create multiple delta files under `changes/[change-id]/specs/<capability>/spec.md`—one per capability.

4. **Create tasks.md:**
```markdown
## 1. Implementation
- [ ] 1.1 Create database schema
- [ ] 1.2 Implement API endpoint
- [ ] 1.3 Add frontend component
- [ ] 1.4 Write tests
```

5. **Create design.md when needed:**
Create `design.md` if any of the following apply; otherwise omit it:
- Cross-cutting change (multiple services/modules) or a new architectural pattern
- New external dependency or significant data model changes
- Security, performance, or migration complexity
- Ambiguity that benefits from technical decisions before coding

Minimal `design.md` skeleton:
```markdown
## Context
[Background, constraints, stakeholders]

## Goals / Non-Goals
- Goals: [...]
- Non-Goals: [...]

## Decisions
- Decision: [What and why]
- Alternatives considered: [Options + rationale]

## Risks / Trade-offs
- [Risk] → Mitigation

## Migration Plan
[Steps, rollback]

## Open Questions
- [...]
```

## Spec File Format

### Critical: Scenario Formatting

**CORRECT** (use #### headers):
```markdown
#### Scenario: User login success
- **WHEN** valid credentials provided
- **THEN** return JWT token
```

**WRONG** (don't use bullets or bold):
```markdown
- **Scenario: User login**  ❌
**Scenario**: User login     ❌
### Scenario: User login      ❌
```

Every requirement MUST have at least one scenario.

### Requirement Wording
- Use SHALL/MUST for normative requirements (avoid should/may unless intentionally non-normative)

### Delta Operations

- `## ADDED Requirements` - New capabilities
- `## MODIFIED Requirements` - Changed behavior
- `## REMOVED Requirements` - Deprecated features
- `## RENAMED Requirements` - Name changes

Headers matched with `trim(header)` - whitespace ignored.

#### When to use ADDED vs MODIFIED
- ADDED: Introduces a new capability or sub-capability that can stand alone as a requirement. Prefer ADDED when the change is orthogonal (e.g., adding "Slash Command Configuration") rather than altering the semantics of an existing requirement.
- MODIFIED: Changes the behavior, scope, or acceptance criteria of an existing requirement. Always paste the full, updated requirement content (header + all scenarios). The archiver will replace the entire requirement with what you provide here; partial deltas will drop previous details.
- RENAMED: Use when only the name changes. If you also change behavior, use RENAMED (name) plus MODIFIED (content) referencing the new name.

Common pitfall: Using MODIFIED to add a new concern without including the previous text. This causes loss of detail at archive time. If you aren’t explicitly changing the existing requirement, add a new requirement under ADDED instead.

Authoring a MODIFIED requirement correctly:
1) Locate the existing requirement in `openspec/specs/<capability>/spec.md`.
2) Copy the entire requirement block (from `### Requirement: ...` through its scenarios).
3) Paste it under `## MODIFIED Requirements` and edit to reflect the new behavior.
4) Ensure the header text matches exactly (whitespace-insensitive) and keep at least one `#### Scenario:`.

Example for RENAMED:
```markdown
## RENAMED Requirements
- FROM: `### Requirement: Login`
- TO: `### Requirement: User Authentication`
```

## Troubleshooting

### Common Errors

**"Change must have at least one delta"**
- Check `changes/[name]/specs/` exists with .md files
- Verify files have operation prefixes (## ADDED Requirements)

**"Requirement must have at least one scenario"**
- Check scenarios use `#### Scenario:` format (4 hashtags)
- Don't use bullet points or bold for scenario headers

**Silent scenario parsing failures**
- Exact format required: `#### Scenario: Name`
- Debug with: `openspec show [change] --json --deltas-only`

### Validation Tips

```bash
# Always use strict mode for comprehensive checks
openspec validate [change] --strict

# Debug delta parsing
openspec show [change] --json | jq '.deltas'

# Check specific requirement
openspec show [spec] --json -r 1
```

## Happy Path Script

```bash
# 1) Explore current state
openspec spec list --long
openspec list
# Optional full-text search:
# rg -n "Requirement:|Scenario:" openspec/specs
# rg -n "^#|Requirement:" openspec/changes

# 2) Choose change id and scaffold
CHANGE=add-two-factor-auth
mkdir -p openspec/changes/$CHANGE/{specs/auth}
printf "## Why\n...\n\n## What Changes\n- ...\n\n## Impact\n- ...\n" > openspec/changes/$CHANGE/proposal.md
printf "## 1. Implementation\n- [ ] 1.1 ...\n" > openspec/changes/$CHANGE/tasks.md

# 3) Add deltas (example)
cat > openspec/changes/$CHANGE/specs/auth/spec.md << 'EOF'
## ADDED Requirements
### Requirement: Two-Factor Authentication
Users MUST provide a second factor during login.

#### Scenario: OTP required
- **WHEN** valid credentials are provided
- **THEN** an OTP challenge is required
EOF

# 4) Validate
openspec validate $CHANGE --strict
```

## Multi-Capability Example

```
openspec/changes/add-2fa-notify/
├── proposal.md
├── tasks.md
└── specs/
    ├── auth/
    │   └── spec.md   # ADDED: Two-Factor Authentication
    └── notifications/
        └── spec.md   # ADDED: OTP email notification
```

auth/spec.md
```markdown
## ADDED Requirements
### Requirement: Two-Factor Authentication
...
```

notifications/spec.md
```markdown
## ADDED Requirements
### Requirement: OTP Email Notification
...
```

## Versioning Conventions

### Version Format
- **Release versions**: `X.Y.Z` (e.g., `1.0.70`) - Only via `cut-release.sh` + GitHub Release
- **Pre-release versions**: `X.Y.Z-preN` (e.g., `1.0.71-pre1`) - For development/testing

### Pre-release Suffixes (auto-detected)
- `-preN` - Pre-release (e.g., `1.0.71-pre1`, `1.0.71-pre2`)
- `-rcN` - Release candidate (e.g., `1.0.71-rc1`)
- `-alphaN` - Alpha release
- `-betaN` - Beta release

### Rules
1. **Never bump to a release version** unless cutting an actual release
2. **Use pre-release versions** for all development work, testing, and Helm chart iterations
3. **Check GitHub Releases** to find the current official version before versioning
4. **Increment pre-release suffix** (`-pre1` → `-pre2`) for iterative dev changes

### Files to Update Together
When changing versions, update ALL of these:
- `VERSION` - App version
- `helm/serviceradar/Chart.yaml` - `version` and `appVersion`
- `k8s/argocd/applications/*.yaml` - `targetRevision` (if deploying)

### Release Workflows

#### Pre-release (for testing)
```bash
# Check current official release
gh release list --limit 1   # e.g., v1.0.70

# Cut a pre-release (auto-detects from version string, skips CHANGELOG)
./scripts/cut-release.sh --version 1.0.71-pre1 --push

# This will:
# - Update VERSION and Chart.yaml to 1.0.71-pre1
# - Create commit "chore: pre-release v1.0.71-pre1"
# - Create tag v1.0.71-pre1
# - Trigger release workflow (marks as prerelease on GitHub)
# - Run e2e tests
```

#### Full release
```bash
# Ensure CHANGELOG has entry for this version
./scripts/cut-release.sh --version 1.0.71 --push

# This will:
# - Update VERSION and Chart.yaml to 1.0.71
# - Create commit "chore: release v1.0.71"
# - Create tag v1.0.71
# - Trigger release workflow (creates full GitHub Release)
```

#### Hotfix release (skip staging tests)
```bash
./scripts/cut-release.sh --version 1.0.71 --hotfix --push
```

### Manual Helm Chart Push (dev only)
For quick iterations without a full release:
```bash
# Update VERSION and Chart.yaml manually
echo "1.0.71-pre2" > VERSION
sed -i 's/^version: .*/version: 1.0.71-pre2/' helm/serviceradar/Chart.yaml
sed -i 's/^appVersion: .*/appVersion: "1.0.71-pre2"/' helm/serviceradar/Chart.yaml

# Package and push
helm package helm/serviceradar
helm push serviceradar-1.0.71-pre2.tgz oci://ghcr.io/carverauto/charts
rm serviceradar-1.0.71-pre2.tgz
```

## Development Environment

### Docker Compose Stack

The `docker-compose.yml` in the project root provides the full development stack. Key services:
- **cnpg** - PostgreSQL with TimescaleDB (port 5455)
- **core** - ServiceRadar core service (ports 8090, 9090, 50052)
- **nats** - NATS messaging (ports 4222, 6222, 8222)
- **datasvc** - Data service (port 50057)

### Starting the Stack

```bash
# Start all services
docker compose up -d

# Check service health
docker compose ps
docker logs serviceradar-core-mtls --tail 50
```

### Database Access

By default, CNPG binds to `127.0.0.1:5455` for security. For remote access during development:

```bash
# Allow external connections (for remote dev)
CNPG_PUBLIC_BIND=0.0.0.0 docker compose up -d cnpg

# Or restart the whole stack with external DB access
CNPG_PUBLIC_BIND=0.0.0.0 docker compose up -d
```

### Elixir Web App (web-ng)

The Phoenix LiveView app in `web-ng/` connects to CNPG. To run locally:

```bash
cd web-ng

# Connect to local docker stack
CNPG_HOST=localhost CNPG_PORT=5455 mix phx.server

# Connect to remote docker host
CNPG_HOST=192.168.2.134 CNPG_PORT=5455 mix phx.server
```

Access the app at http://localhost:4000

### Elixir Core App (core-elx)

The core Elixir app in `elixir/serviceradar_core/` handles background jobs, NATS integration, and tenant infrastructure. **Prefer running standalone for faster iteration over Docker rebuilds.**

#### First-time Setup

```bash
cd elixir/serviceradar_core

# Install dependencies
mix deps.get

# Compile
mix compile
```

#### Running Standalone

The core app needs TLS certs for connecting to datasvc and CNPG. Use `.local-dev-certs/` directory (generated by docker compose cert-generator):

```bash
cd elixir/serviceradar_core

# Run with local docker services (datasvc, cnpg, nats)
DATASVC_HOST=localhost \
DATASVC_PORT=50057 \
DATASVC_SSL=true \
DATASVC_CERT_DIR=/home/mfreeman/serviceradar/.local-dev-certs \
DATASVC_CERT_NAME=core \
DATASVC_SERVER_NAME=datasvc.serviceradar \
CNPG_HOST=localhost \
CNPG_PORT=5455 \
CNPG_SSL_MODE=verify-full \
CNPG_CERT_DIR=/home/mfreeman/serviceradar/.local-dev-certs \
CNPG_TLS_SERVER_NAME=cnpg \
NATS_URL=nats://localhost:4222 \
NATS_TLS=true \
NATS_SERVER_NAME=nats.serviceradar \
iex -S mix
```

For convenience, create a shell script `scripts/run-core-elx.sh`:

```bash
#!/bin/bash
cd "$(dirname "$0")/../elixir/serviceradar_core"
export DATASVC_HOST=localhost
export DATASVC_PORT=50057
export DATASVC_SSL=true
export DATASVC_CERT_DIR="$(pwd)/../../.local-dev-certs"
export DATASVC_CERT_NAME=core
export DATASVC_SERVER_NAME=datasvc.serviceradar
export CNPG_HOST=localhost
export CNPG_PORT=5455
export CNPG_SSL_MODE=verify-full
export CNPG_CERT_DIR="$(pwd)/../../.local-dev-certs"
export CNPG_TLS_SERVER_NAME=cnpg
export NATS_URL=nats://localhost:4222
export NATS_TLS=true
export NATS_SERVER_NAME=nats.serviceradar
exec iex -S mix
```

#### Required Services

Before running core-elx standalone, ensure these docker services are running:
- `datasvc` - gRPC data service (port 50057)
- `cnpg` - PostgreSQL database (port 5455)
- `nats` - NATS messaging (port 4222)

```bash
# Start only required services
docker compose up -d cert-generator cert-permissions-fixer cnpg nats datasvc
```

#### TLS Certificates

If `.local-dev-certs/` doesn't exist or is stale:
```bash
# Generate certs using docker compose
docker compose up -d cert-generator cert-permissions-fixer

# Copy certs from volume to local directory
docker cp serviceradar-cert-generator-mtls:/certs .local-dev-certs
```

### Environment Variables

Common development overrides:
| Variable | Default | Description |
|----------|---------|-------------|
| `CNPG_PUBLIC_BIND` | `127.0.0.1` | Database bind address |
| `CNPG_PUBLIC_PORT` | `5455` | Database external port |
| `CNPG_HOST` | `cnpg` (in docker) | Database hostname |
| `CNPG_PORT` | `5432` | Database port |
| `CNPG_USERNAME` | `serviceradar` | Database user |
| `CNPG_PASSWORD` | `serviceradar` | Database password |
| `APP_TAG` | `v1.0.67` | Container image tag |

### Rebuilding After Code Changes

```bash
# Rebuild specific service with git SHA tag (for dev)
APP_TAG=sha-$(git rev-parse --short HEAD) docker compose up -d --build core

# Or pull latest from registry
APP_TAG=v1.0.78 docker compose pull && APP_TAG=v1.0.78 docker compose up -d
```

## Elixir / Ash Framework Rules

### Absolute Rules (No Exceptions)

1. **Everything through Ash** - ALL database entities MUST be Ash resources. No raw SQL queries, no Ecto-only schemas. Every table gets an Ash resource.

2. **All migrations through Ash** - Use the Ash codegen workflow (see below). NEVER use `mix ecto.migrate` or `mix ecto.gen.migration`.

3. **SRQL through Ash Adapter** - ALL SRQL queries route through the AshAdapter. No bypassing to raw SQL.

### Ash Codegen Workflow

The correct workflow for schema changes:

```bash
# 1. Make changes to Ash resources (.ex files)

# 2. Development iteration (temporary migrations)
mix ash.codegen --dev

# 3. Apply dev migrations
mix ash.migrate

# 4. When ready to commit, generate final migration with name
mix ash.codegen add_user_preferences

# 5. Apply and verify
mix ash.migrate

# 6. If needed, rollback with
mix ash.rollback
```

**Key Commands:**
| Command | Purpose |
|---------|---------|
| `mix ash.codegen --dev` | Generate temporary dev migrations |
| `mix ash.codegen <name>` | Generate final named migration |
| `mix ash.migrate` | Run all pending migrations |
| `mix ash.rollback` | Rollback last migration |

**NEVER use:**
- ❌ `mix ecto.migrate` - Wrong migration tracking table
- ❌ `mix ecto.gen.migration` - Creates Ecto-only migration
- ❌ `mix ecto.rollback` - Wrong migration tracking table

### Special Cases (TimescaleDB, Composite Keys)

For tables with special requirements (TimescaleDB hypertables, composite primary keys, materialized views):

1. **Create Ash resource with `migrate?: false`** - The resource maps to the table but Ash won't try to generate migrations for it:
   ```elixir
   postgres do
     table "otel_metrics"
     repo ServiceRadar.Repo
     migrate? false  # Table managed separately
   end
   ```

2. **Create raw SQL migration** - Place in `priv/repo/migrations/` with explicit schema that matches Go/external requirements:
   ```elixir
   defmodule MyApp.Repo.Migrations.CreateOtelTables do
     use Ecto.Migration

     def up do
       execute "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE"
       execute """
       CREATE TABLE otel_metrics (
         timestamp TIMESTAMPTZ NOT NULL,
         ...
         PRIMARY KEY (timestamp, span_name, service_name, span_id)
       )
       """
       execute "SELECT create_hypertable('otel_metrics', 'timestamp')"
     end
   end
   ```

3. **Match schema exactly** - Ash resource attributes MUST match the table columns exactly (types, names, nullability).

4. **Composite primary keys** - Use `primary_key?: true` on multiple attributes:
   ```elixir
   attributes do
     attribute :timestamp, :utc_datetime_usec, primary_key?: true, allow_nil?: false
     attribute :trace_id, :string, primary_key?: true, allow_nil?: false
     attribute :span_id, :string, primary_key?: true, allow_nil?: false
   end
   ```

### Common Patterns

- **Domains organize resources** - Each domain (Inventory, Monitoring, Observability) groups related resources
- **Policies for authorization** - Use `Ash.Policy.Authorizer` for all access control
- **Multi-tenancy via attribute** - Use `tenant_id` attribute strategy where applicable
- **Read-only resources** - For views/CAGGs, only define `:read` actions

### What NOT to do

- ❌ Use Ecto schemas without Ash resources
- ❌ Write raw SQL in controllers or contexts
- ❌ Bypass AshAdapter for SRQL queries
- ❌ Use `mix ecto.migrate` for application tables
- ❌ Create Ecto migrations with `mix ecto.gen.migration`

## Best Practices

### Simplicity First
- Default to <100 lines of new code
- Single-file implementations until proven insufficient
- Avoid frameworks without clear justification
- Choose boring, proven patterns

### Complexity Triggers
Only add complexity with:
- Performance data showing current solution too slow
- Concrete scale requirements (>1000 users, >100MB data)
- Multiple proven use cases requiring abstraction

### Clear References
- Use `file.ts:42` format for code locations
- Reference specs as `specs/auth/spec.md`
- Link related changes and PRs

### Capability Naming
- Use verb-noun: `user-auth`, `payment-capture`
- Single purpose per capability
- 10-minute understandability rule
- Split if description needs "AND"

### Change ID Naming
- Use kebab-case, short and descriptive: `add-two-factor-auth`
- Prefer verb-led prefixes: `add-`, `update-`, `remove-`, `refactor-`
- Ensure uniqueness; if taken, append `-2`, `-3`, etc.

## Tool Selection Guide

| Task | Tool | Why |
|------|------|-----|
| Find files by pattern | Glob | Fast pattern matching |
| Search code content | Grep | Optimized regex search |
| Read specific files | Read | Direct file access |
| Explore unknown scope | Task | Multi-step investigation |

## Error Recovery

### Change Conflicts
1. Run `openspec list` to see active changes
2. Check for overlapping specs
3. Coordinate with change owners
4. Consider combining proposals

### Validation Failures
1. Run with `--strict` flag
2. Check JSON output for details
3. Verify spec file format
4. Ensure scenarios properly formatted

### Missing Context
1. Read project.md first
2. Check related specs
3. Review recent archives
4. Ask for clarification

## Quick Reference

### Stage Indicators
- `changes/` - Proposed, not yet built
- `specs/` - Built and deployed
- `archive/` - Completed changes

### File Purposes
- `proposal.md` - Why and what
- `tasks.md` - Implementation steps
- `design.md` - Technical decisions
- `spec.md` - Requirements and behavior

### CLI Essentials
```bash
openspec list              # What's in progress?
openspec show [item]       # View details
openspec validate --strict # Is it correct?
openspec archive <change-id> [--yes|-y]  # Mark complete (add --yes for automation)
```

Remember: Specs are truth. Changes are proposals. Keep them in sync.
