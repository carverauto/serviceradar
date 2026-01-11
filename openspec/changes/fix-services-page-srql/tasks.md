# Tasks: Fix Services Page and SRQL Integration

## 1. Investigation and Analysis

- [ ] 1.1 Reproduce TimeFilterSpec serialization error in isolation
- [ ] 1.2 Trace tenant context flow from LiveView -> SRQL -> AshAdapter -> Ash
- [ ] 1.3 Identify all SRQL entities that require tenant context
- [ ] 1.4 Review ServiceCheck vs ServiceStatus data model requirements

## 2. Fix TimeFilterSpec Serialization (Rust NIF)

- [ ] 2.1 Locate TimeFilterSpec enum definition in `native/srql_nif/src/`
- [ ] 2.2 Add proper serde serialization for `RelativeHours` variant
- [ ] 2.3 Add proper serde serialization for `RelativeDays` variant
- [ ] 2.4 Add tests for all TimeFilterSpec variants
- [ ] 2.5 Rebuild NIF and verify serialization works

## 3. Fix Tenant Context Propagation (AshAdapter)

- [ ] 3.1 Update `query/2` in ash_adapter.ex to accept actor option
- [ ] 3.2 Extract tenant_id from actor for context-based multitenancy resources
- [ ] 3.3 Pass tenant option to Ash.read/2 and related calls
- [ ] 3.4 Update services page LiveView to pass current_scope to SRQL queries
- [ ] 3.5 Update analytics page LiveView to pass current_scope to SRQL queries
- [ ] 3.6 Add error handling for missing tenant context

## 4. Update SRQL Catalog for Services

- [ ] 4.1 Review services entity field mappings match ServiceCheck schema
- [ ] 4.2 Add any missing filter fields (tenant_id, agent_uid, device_uid)
- [ ] 4.3 Ensure timestamp field mapping is correct (last_check_at)
- [ ] 4.4 Test services queries with proper tenant context

## 5. Update Services Page

- [ ] 5.1 Verify gateways panel works with tenant context
- [ ] 5.2 Verify service summary calculations work
- [ ] 5.3 Verify service checks table displays correct data
- [ ] 5.4 Add loading states and error handling
- [ ] 5.5 Consider renaming to "Health Checks" if more accurate

## 6. Update Analytics Page

- [ ] 6.1 Fix services_list SRQL query with tenant context
- [ ] 6.2 Verify Active Services stat card shows correct count
- [ ] 6.3 Verify Failing Services stat card shows correct count
- [ ] 6.4 Add fallback for when services data is unavailable

## 7. Testing

- [ ] 7.1 Add unit tests for TimeFilterSpec serialization
- [ ] 7.2 Add unit tests for AshAdapter tenant propagation
- [ ] 7.3 Add integration tests for services SRQL queries
- [ ] 7.4 Manual testing of services page with real data
- [ ] 7.5 Manual testing of analytics page services cards

## 8. Documentation

- [ ] 8.1 Update SRQL catalog documentation
- [ ] 8.2 Document tenant context requirements for SRQL queries
- [ ] 8.3 Close GitHub issue #2234
