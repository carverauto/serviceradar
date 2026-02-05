## 1. Data Model & Policies
- [ ] 1.1 Add migrations for user status fields and role mapping configuration (platform schema)
- [ ] 1.2 Extend Identity domain resources/actions for user lifecycle (create, update, deactivate/reactivate, role change)
- [ ] 1.3 Enforce Ash policies for admin-only user management actions
- [ ] 1.4 Add audit events for user lifecycle and authz setting changes

## 2. API & Backend Flows
- [ ] 2.1 Add admin APIs for user listing, filtering, and lifecycle actions
- [ ] 2.2 Add role mapping evaluation during login and user provisioning
- [ ] 2.3 Ensure deactivation revokes sessions and API tokens

## 3. Web UI
- [ ] 3.1 Add Settings -> Auth navigation entry
- [ ] 3.2 Build Users tab (list, create/invite, edit role, deactivate/reactivate)
- [ ] 3.3 Build Authorization tab (default role, IdP group/claim mapping)
- [ ] 3.4 Add confirmation flows and error states for admin actions

## 4. Tests & Docs
- [ ] 4.1 Add backend tests for user lifecycle policies and role mapping
- [ ] 4.2 Add UI tests/coverage for auth settings flows
- [ ] 4.3 Update docs/runbooks for managing users and roles
