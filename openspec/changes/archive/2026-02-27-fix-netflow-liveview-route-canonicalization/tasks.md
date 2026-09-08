## 1. Implementation
- [x] 1.1 Ensure NetFlow LiveView URL builders and fallback paths use the canonical `/flows` LiveView root.
- [x] 1.2 Remove `/netflow` and `/netflows` routes from the router so `/flows` is the only supported path.
- [x] 1.3 Add/extend LiveView tests for canonical `/flows` routing and patch safety.

## 2. Validation
- [x] 2.1 Run `openspec validate fix-netflow-liveview-route-canonicalization --strict`.
- [x] 2.2 Run focused web-ng tests for NetFlow LiveView route/patch behavior.
