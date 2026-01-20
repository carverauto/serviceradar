## 1. Implementation

- [x] 1.1 Update `upsert_interface_payload/1` to use text-cast pattern for AGE queries
- [x] 1.2 Update `upsert_link_payload/1` to use text-cast pattern for AGE queries
- [x] 1.3 Extract shared AGE query execution helper (`execute_cypher/1`)

## 2. Testing

- [x] 2.1 Verify code compiles without errors
- [ ] 2.2 Verify existing `mapper_graph_ingestion_test.exs` passes (requires database)
- [ ] 2.3 Integration test with running docker stack

## 3. Verification

- [ ] 3.1 Run docker compose stack and trigger interface/link upserts
- [ ] 3.2 Confirm no `agtype` Postgrex errors in logs
- [ ] 3.3 Verify graph data is correctly persisted
