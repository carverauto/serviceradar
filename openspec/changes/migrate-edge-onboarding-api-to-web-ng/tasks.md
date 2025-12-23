# Tasks: Migrate Edge Onboarding API to web-ng

## 1. Database Layer

- [x] 1.1 Add Ecto schema for `EdgeOnboardingEvent` (`edge_onboarding_events` table)
- [x] 1.2 Add changeset validations for package creation (label required, TTL bounds)
- [x] 1.3 Add query functions for listing packages with filters (status, component_type, poller_id)
- [x] 1.4 Add query functions for listing package events with pagination
- [x] 1.5 Write unit tests for Ecto schemas and changesets

## 2. Edge Context Business Logic

- [x] 2.1 Implement `Edge.OnboardingPackages.list/1` with filter support
- [x] 2.2 Implement `Edge.OnboardingPackages.get/1` by package_id
- [x] 2.3 Implement `Edge.OnboardingPackages.create/1` with token generation
- [x] 2.4 Implement `Edge.OnboardingPackages.deliver/2` for package download
- [x] 2.5 Implement `Edge.OnboardingPackages.revoke/2` for package revocation
- [x] 2.6 Implement `Edge.OnboardingPackages.delete/1` for soft-delete
- [x] 2.7 Implement `Edge.OnboardingPackages.defaults/0` for selectors/metadata
- [x] 2.8 Implement `Edge.OnboardingEvents.list_for_package/2` with limit
- [x] 2.9 Implement `Edge.OnboardingEvents.record/1` for audit logging (with Oban)
- [x] 2.10 Write unit tests for context functions

## 3. Component Templates

- [x] 3.1 Add datasvc gRPC client module (`ServiceRadarWebNG.Datasvc`, `Datasvc.KV`)
- [x] 3.2 Implement `Edge.ComponentTemplates.list/2` (component_type, security_mode)
- [x] 3.3 Write tests for template listing
- [x] 3.4 Add mTLS support to datasvc gRPC client
- [x] 3.5 Add GRPC.Client.Supervisor to application supervision tree
- [x] 3.6 Configure datasvc connectivity in docker-compose (DATASVC_ADDRESS)

> **Note:** Templates endpoint uses datasvc gRPC to query NATS JetStream KV with mTLS authentication.

## 4. Token/Crypto Integration

- [x] 4.1 Port or integrate secrets encryption for join_token_ciphertext (AES-256-GCM)
- [x] 4.2 Port or integrate download_token hashing (SHA256)
- [x] 4.3 Implement token verification for package delivery
- [x] 4.4 Write tests for token round-trip and verification

## 5. API Controllers

- [x] 5.1 Create `EdgeController` with JSON API handlers
- [x] 5.2 Implement `GET /api/admin/edge-packages/defaults`
- [x] 5.3 Implement `GET /api/admin/edge-packages` with query params
- [x] 5.4 Implement `POST /api/admin/edge-packages`
- [x] 5.5 Implement `GET /api/admin/edge-packages/:id`
- [x] 5.6 Implement `DELETE /api/admin/edge-packages/:id`
- [x] 5.7 Implement `GET /api/admin/edge-packages/:id/events`
- [x] 5.8 Implement `POST /api/admin/edge-packages/:id/download`
- [x] 5.9 Implement `POST /api/admin/edge-packages/:id/revoke`
- [x] 5.10 Implement `GET /api/admin/component-templates` (uses datasvc gRPC)
- [x] 5.11 Add special auth handling for download endpoint (token-gated unauthenticated)

## 6. Router Configuration

- [x] 6.1 Add edge API routes under `/api/admin` scope
- [x] 6.2 Configure authentication pipeline (allow unauthenticated download with valid token)
- [ ] 6.3 Add OpenAPI documentation (if using open_api_spex)

## 7. Integration Testing

- [x] 7.1 Write controller tests for all endpoints (21 tests)
- [x] 7.2 Write integration tests for full create-deliver-revoke lifecycle
- [x] 7.3 Test error cases (not found, expired token, already revoked)
- [x] 7.4 Test filter combinations for list endpoints

## 8. Admin UI

- [x] 8.1 Create `EdgePackageLive.Index` LiveView for admin UI
- [x] 8.2 Implement package list with status badges and filters
- [x] 8.3 Implement create package modal with token display
- [x] 8.4 Implement package details view with events
- [x] 8.5 Add admin navigation tabs (Jobs / Edge Onboarding)
- [x] 8.6 Add router routes for `/admin/edge-packages`
- [x] 8.7 Add checker template dropdown (fetched from datasvc KV)
- [x] 8.8 Add checker_kind and checker_config_json fields for checker packages
- [x] 8.9 Add environment-based security mode configuration

## 9. Documentation

- [ ] 9.1 Add API documentation to docs site
- [ ] 9.2 Update deployment docs for new routing
- [ ] 9.3 Add OpenAPI documentation (if using open_api_spex)

---

## Summary

**Completed:** 47/50 tasks (94%)

**Core API functionality is complete and tested.** Admin UI implemented with:
- Full CRUD operations for edge onboarding packages
- Checker template selection from NATS KV via datasvc gRPC
- mTLS authentication to datasvc
- Environment-based security mode configuration

**Deferred:**
- OpenAPI documentation (6.3, 9.3)
- Docs site updates (9.1, 9.2)
