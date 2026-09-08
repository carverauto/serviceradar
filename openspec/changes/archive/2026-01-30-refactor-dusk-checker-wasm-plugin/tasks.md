# Tasks: Refactor Dusk Checker to WASM Plugin

## 1. SDK WebSocket Support ✅

- [x] 1.1 Add WebSocket host function declarations to `sdk/host_tinygo.go`
- [x] 1.2 Add WebSocket stub implementations to `sdk/host_stub.go`
- [x] 1.3 Create `sdk/websocket.go` with `WebSocketConn` wrapper and context-aware methods
- [x] 1.4 Add `websocket_connect` capability constant

## 2. Agent WebSocket Host Functions ✅

- [x] 2.1 Implement `hostWebSocketConnect` in `pkg/agent/plugin_runtime.go`
- [x] 2.2 Implement `hostWebSocketSend` for sending WebSocket frames
- [x] 2.3 Implement `hostWebSocketRecv` for receiving WebSocket frames
- [x] 2.4 Implement `hostWebSocketClose` for connection cleanup
- [x] 2.5 Add WebSocket connection tracking to `pluginExecution`
- [x] 2.6 Add `websocket_connect` capability check

## 3. Plugin Development ✅

- [x] 3.1 Set up `serviceradar-plugins` repo structure (Go + Rust layout)
- [x] 3.2 Create `go/dusk-checker/` plugin directory
- [x] 3.3 Implement `main.go` with `run_check()` export using SDK
- [x] 3.4 Port RUES protocol handling (session ID, block subscription)
- [x] 3.5 Implement block event parsing and result construction
- [x] 3.6 Create plugin manifest (`plugin.yaml`) with WebSocket capability
- [x] 3.7 Add TinyGo build configuration and Makefile

### TinyGo Workarounds Discovered

- **Config Loading**: TinyGo requires explicit `json.Unmarshal` call with the config type to include reflection metadata. See `main.go` lines 42-44.
- **Map Serialization**: TinyGo has issues with map iteration during JSON marshalling. `WithLabel` and `WithMetric` cause runtime errors. For now, include all info in summary text.

## 4. Agent Code Removal ✅

- [x] 4.1 Remove `pkg/agent/dusk_service.go` and `dusk_service_test.go`
- [x] 4.2 Remove dusk initialization from `pkg/agent/server.go`
- [x] 4.3 Remove dusk config application from `pkg/agent/push_loop.go`
- [x] 4.4 Remove `pkg/checker/dusk/` directory entirely
- [x] 4.5 Update `pkg/agent/BUILD.bazel` to remove dusk dependencies
- [x] 4.6 Add gorilla/websocket dependency for host WebSocket functions

## 5. Control Plane Updates (Deferred)

> These changes are deferred until the plugin is tested against a real Dusk node.

- [ ] 5.1 Remove `DuskCompiler` from agent config compilers
- [ ] 5.2 Update `DuskProfile` to generate plugin assignments
- [ ] 5.3 Remove dusk-specific fields from agent config proto
- [ ] 5.4 Regenerate proto stubs

## 6. Testing (Partial)

- [x] 6.1 Unit test WebSocket SDK wrapper (via `TestDuskCheckerWithConfig`)
- [x] 6.2 Unit test agent WebSocket host functions (via `TestDuskCheckerWithConfig`)
- [ ] 6.3 Integration test: plugin connects to real Dusk node (requires deployment)
- [ ] 6.4 End-to-end test: control plane assigns plugin, agent executes, gateway receives status

## 7. Documentation (Deferred)

- [ ] 7.1 Update dusk monitoring docs with plugin-based setup
- [ ] 7.2 Add dusk-checker as SDK example

## Completion Summary

| Section | Status |
|---------|--------|
| SDK WebSocket Support | ✅ Complete |
| Agent WebSocket Host Functions | ✅ Complete |
| Plugin Development | ✅ Complete |
| Agent Code Removal | ✅ Complete |
| Control Plane Updates | ⏸️ Deferred |
| Testing | 🟡 Partial |
| Documentation | ⏸️ Deferred |

**Ready for**: Deployment and real Dusk node testing
