# Tasks: Fix config compilers executing on agent-gateway

## 1. Remove database components from agent-gateway

- [x] 1.1 Remove `repo_child()` from the children list in `application.ex`
- [x] 1.2 Remove the `repo_child()` function definition
- [ ] 1.3 Verify gateway starts successfully without Repo

## 2. Improve core node detection in agent-gateway

- [x] 2.1 Update `core_nodes()` to exclude `Node.self()` from the candidate list (gateway should never RPC to itself for DB operations)
- [x] 2.2 Remove the fallback to Repo-based node detection - require `ClusterHealth` for DB-dependent calls
- [x] 2.3 Add clear logging when no core nodes are available

## 3. Testing

- [ ] 3.1 Verify agent config requests are always forwarded to core-elx via RPC
- [ ] 3.2 Verify gateway handles core unavailability gracefully (returns appropriate error to agents)
- [ ] 3.3 Verify sweep configurations compile successfully on core-elx
