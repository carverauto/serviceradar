## 1. Database Schema

- [x] 1.1 Create migration file `00000000000008_ocsf_agents.up.sql` with `ocsf_agents` table
- [x] 1.2 Create down migration `00000000000008_ocsf_agents.down.sql`
- [x] 1.3 Add indexes for uid, poller_id, type_id, last_seen_time
- [ ] 1.4 Test migration locally with `docker compose up cnpg`

## 2. Agent Model (Go)

- [x] 2.1 Create `pkg/models/ocsf_agent.go` with OCSF-aligned struct
- [x] 2.2 Add type_id enum constants matching OCSF Agent types
- [x] 2.3 Add helper functions `CreateOCSFAgentFromRegistration()`

## 3. Registry Repository

- [x] 3.1 Add `UpsertOCSFAgent()` method to registry repository
- [x] 3.2 Add `GetOCSFAgent()` method for single agent lookup
- [x] 3.3 Add `ListOCSFAgents()` method with pagination and filters
- [x] 3.4 Add `ListOCSFAgentsByPoller()` method for poller-scoped queries
- [ ] 3.5 Write unit tests for repository methods

## 4. Registration Flow

- [x] 4.1 Create `registerAgentInOCSF()` function in `pkg/core/pollers.go`
- [x] 4.2 Extract agent version from service metadata if available
- [x] 4.3 Update `processIndividualServices()` to call `registerAgentInOCSF()` instead of `registerAgentAsDevice()`
- [x] 4.4 Remove `registerAgentAsDevice()` function (fully deleted, not deprecated)
- [x] 4.5 Update `registerCheckerAsDevice()` to not create agent device entries
- [ ] 4.6 Test with local poller/agent to verify registration

## 5. SRQL Query Support

- [x] 5.1 Add `ocsf_agents` table to `rust/srql/src/schema.rs` (diesel schema)
- [x] 5.2 Create `AgentRow` struct in `rust/srql/src/models.rs`
- [x] 5.3 Create `rust/srql/src/query/agents.rs` with query execution logic
- [x] 5.4 Add `Entity::Agents` variant to parser in `rust/srql/src/parser.rs`
- [x] 5.5 Register agents query module in `rust/srql/src/query/mod.rs`
- [x] 5.6 Support filters: `type_id`, `poller_id`, `capabilities`, `name`, `version`
- [x] 5.7 Support ordering by `last_seen_time`, `first_seen_time`, `name`
- [ ] 5.8 Support `stats count` for agent totals
- [ ] 5.9 Add agents table to test fixtures `rust/srql/tests/fixtures/schema.sql`
- [ ] 5.10 Add agent seed data to `rust/srql/tests/fixtures/seed.sql`
- [ ] 5.11 Write SRQL integration tests for agent queries

## 6. Web-NG Agent Views

- [x] 6.1 Create `lib/serviceradar_web_ng_web/live/agent_live/index.ex` - Agent list view
- [x] 6.2 Create `lib/serviceradar_web_ng_web/live/agent_live/show.ex` - Agent detail view
- [x] 6.3 Add agent routes to `router.ex`
- [x] 6.4 Create agent list component with table (uid, name, type, version, poller, last_seen)
- [x] 6.5 Create agent detail component showing full OCSF fields and capabilities
- [ ] 6.6 Add agent count card to dashboard/overview page
- [x] 6.7 Add sidebar navigation link to Agents section
- [ ] 6.8 Add agent health status indicators (based on last_seen_time threshold)
- [x] 6.9 All agent data queries MUST use SRQL via `/api/query` endpoint

## 7. Device Agent List Update

- [x] 7.1 Add agents section to device show page with links to `/agents/:uid`
- [x] 7.2 Display agent_list from device with type badges and navigation

## 8. Code Cleanup

- [x] 8.1 Remove `CreateAgentDeviceUpdate()` helper from `pkg/models/service_registration.go`
- [x] 8.2 Update tests in `pkg/models/service_device_test.go` to remove agent-as-device assertions
- [x] 8.3 Update tests in `pkg/registry/service_device_test.go` to remove agent-as-device tests
- [ ] 8.4 Regenerate mock interfaces (`go generate ./pkg/db/...`) for new OCSF agent methods

## 9. Integration Testing

- [ ] 9.1 Add integration test for agent registration flow
- [ ] 9.2 Verify agents no longer appear in device inventory
- [ ] 9.3 Verify agents queryable via SRQL `agents` entity
- [ ] 9.4 Test poller heartbeat flow end-to-end
- [ ] 9.5 Test web-ng agent views render correctly with SRQL data

## 10. Documentation

- [ ] 10.1 Update docs/docs/agents.md with OCSF alignment notes
- [ ] 10.2 Document SRQL `agents` entity and supported filters
- [ ] 10.3 Add UI screenshots to documentation
