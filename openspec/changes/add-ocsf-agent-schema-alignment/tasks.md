## 1. Database Schema

- [ ] 1.1 Create migration file `00000000000010_ocsf_agents.up.sql` with `ocsf_agents` table
- [ ] 1.2 Create down migration `00000000000010_ocsf_agents.down.sql`
- [ ] 1.3 Add indexes for uid, poller_id, type_id, last_seen_time
- [ ] 1.4 Test migration locally with `docker compose up cnpg`

## 2. Agent Model

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

## 5. API Endpoints

- [ ] 5.1 Create `pkg/core/api/agent_registry.go` with handler struct
- [ ] 5.2 Add `GET /api/agents` - List all agents with pagination
- [ ] 5.3 Add `GET /api/agents/:id` - Get single agent details
- [ ] 5.4 Add `GET /api/agents/by-poller/:pollerId` - Agents for a poller
- [ ] 5.5 Register routes in API server setup
- [ ] 5.6 Add API tests for new endpoints

## 6. Device Agent List Update

- [ ] 6.1 Update device creation to reference `ocsf_agents` for `agent_list` field
- [ ] 6.2 Ensure OCSF Agent object format in `agent_list` JSONB

## 7. Integration Testing

- [ ] 7.1 Add integration test for agent registration flow
- [ ] 7.2 Verify agents no longer appear in device inventory
- [ ] 7.3 Verify agents appear in agent registry API
- [ ] 7.4 Test poller heartbeat flow end-to-end

## 8. Documentation

- [ ] 8.1 Update docs/docs/agents.md with OCSF alignment notes
- [ ] 8.2 Add API documentation for new agent endpoints
