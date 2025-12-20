## 1. Database Schema

- [ ] 1.1 Create migration file `00000000000010_ocsf_agents.up.sql` with `ocsf_agents` table
- [ ] 1.2 Create down migration `00000000000010_ocsf_agents.down.sql`
- [ ] 1.3 Add indexes for uid, poller_id, type_id, last_seen_time
- [ ] 1.4 Test migration locally with `docker compose up cnpg`

## 2. Agent Model (Go)

- [ ] 2.1 Create `pkg/models/ocsf_agent.go` with OCSF-aligned struct
- [ ] 2.2 Add type_id enum constants matching OCSF Agent types
- [ ] 2.3 Add helper functions `CreateOCSFAgentFromRegistration()`

## 3. Registry Repository

- [ ] 3.1 Add `UpsertOCSFAgent()` method to registry repository
- [ ] 3.2 Add `GetOCSFAgent()` method for single agent lookup
- [ ] 3.3 Add `ListOCSFAgents()` method with pagination and filters
- [ ] 3.4 Add `GetAgentsByPoller()` method for poller-scoped queries
- [ ] 3.5 Write unit tests for repository methods

## 4. Registration Flow

- [ ] 4.1 Create `registerAgentInOCSF()` function in `pkg/core/pollers.go`
- [ ] 4.2 Extract agent version from service metadata if available
- [ ] 4.3 Update `processIndividualServices()` to call `registerAgentInOCSF()` instead of `registerAgentAsDevice()`
- [ ] 4.4 Remove (or deprecate) `registerAgentAsDevice()` function
- [ ] 4.5 Update `registerCheckerAsDevice()` to not create agent device entries
- [ ] 4.6 Test with local poller/agent to verify registration

## 5. SRQL Query Support

- [ ] 5.1 Add `ocsf_agents` table to `rust/srql/src/schema.rs` (diesel schema)
- [ ] 5.2 Create `AgentRow` struct in `rust/srql/src/models.rs`
- [ ] 5.3 Create `rust/srql/src/query/agents.rs` with query execution logic
- [ ] 5.4 Add `Entity::Agents` variant to parser in `rust/srql/src/parser.rs`
- [ ] 5.5 Register agents query module in `rust/srql/src/query/mod.rs`
- [ ] 5.6 Support filters: `type_id`, `poller_id`, `capabilities`, `name`, `version`
- [ ] 5.7 Support ordering by `last_seen_time`, `first_seen_time`, `name`
- [ ] 5.8 Support `stats count` for agent totals
- [ ] 5.9 Add agents table to test fixtures `rust/srql/tests/fixtures/schema.sql`
- [ ] 5.10 Add agent seed data to `rust/srql/tests/fixtures/seed.sql`
- [ ] 5.11 Write SRQL integration tests for agent queries

## 6. Web-NG Agent Views

- [ ] 6.1 Create `lib/serviceradar_web_ng_web/live/agent_live/index.ex` - Agent list view
- [ ] 6.2 Create `lib/serviceradar_web_ng_web/live/agent_live/show.ex` - Agent detail view
- [ ] 6.3 Add agent routes to `router.ex`
- [ ] 6.4 Create agent list component with table (uid, name, type, version, poller, last_seen)
- [ ] 6.5 Create agent detail component showing full OCSF fields and capabilities
- [ ] 6.6 Add agent count card to dashboard/overview page
- [ ] 6.7 Add sidebar navigation link to Agents section
- [ ] 6.8 Add agent health status indicators (based on last_seen_time threshold)
- [ ] 6.9 All agent data queries MUST use SRQL via `/api/query` endpoint

## 7. Device Agent List Update

- [ ] 7.1 Update device creation to reference `ocsf_agents` for `agent_list` field
- [ ] 7.2 Ensure OCSF Agent object format in `agent_list` JSONB

## 8. Integration Testing

- [ ] 8.1 Add integration test for agent registration flow
- [ ] 8.2 Verify agents no longer appear in device inventory
- [ ] 8.3 Verify agents queryable via SRQL `agents` entity
- [ ] 8.4 Test poller heartbeat flow end-to-end
- [ ] 8.5 Test web-ng agent views render correctly with SRQL data

## 9. Documentation

- [ ] 9.1 Update docs/docs/agents.md with OCSF alignment notes
- [ ] 9.2 Document SRQL `agents` entity and supported filters
- [ ] 9.3 Add UI screenshots to documentation
