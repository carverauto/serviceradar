## 1. Implementation
- [x] 1.1 Add a paginated device fetch helper (follow `next` until empty) for the NetBox integration
- [x] 1.2 Update `pkg/sync/integrations/netbox/netbox.go:Fetch` to use paginated fetching and log total devices discovered
- [x] 1.3 Update `pkg/sync/integrations/netbox/netbox.go:Reconcile` to use paginated fetching and abort before generating retractions on any fetch error

## 2. Tests
- [x] 2.1 Add a unit test proving discovery fetches all pages (httptest server returns `next`)
- [x] 2.2 Add a unit test proving reconciliation does not retract devices that exist on page 2+
- [x] 2.3 Add a unit test proving mid-pagination failures return an error and do not emit partial results/retractions

## 3. Validation
- [x] 3.1 Run `openspec validate fix-netbox-pagination --strict`
- [x] 3.2 Run `go test ./pkg/sync/integrations/netbox/...`

## 4. Documentation (Optional)
- [ ] 4.1 Confirm `docs/docs/netbox.md` mentions pagination behavior and adjust wording if it implies only the first page is fetched
