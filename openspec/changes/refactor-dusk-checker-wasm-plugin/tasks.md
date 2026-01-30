# Tasks: Refactor Dusk Checker to WASM Plugin

## 1. SDK WebSocket Support

- [ ] 1.1 Add WebSocket host function declarations to `sdk/host_tinygo.go`
- [ ] 1.2 Add WebSocket stub implementations to `sdk/host_stub.go`
- [ ] 1.3 Create `sdk/websocket.go` with `WebSocketConn` wrapper and context-aware methods
- [ ] 1.4 Add `websocket_connect` capability constant

## 2. Agent WebSocket Host Functions

- [ ] 2.1 Implement `hostWebSocketConnect` in `pkg/agent/plugin_runtime.go`
- [ ] 2.2 Implement `hostWebSocketSend` for sending WebSocket frames
- [ ] 2.3 Implement `hostWebSocketRecv` for receiving WebSocket frames
- [ ] 2.4 Implement `hostWebSocketClose` for connection cleanup
- [ ] 2.5 Add WebSocket connection tracking to `pluginExecution`
- [ ] 2.6 Add `websocket_connect` capability check

## 3. Plugin Development

- [ ] 3.1 Set up `serviceradar-plugins` repo structure (Go + Rust layout)
- [ ] 3.2 Create `go/dusk-checker/` plugin directory
- [ ] 3.3 Implement `main.go` with `run_check()` export using SDK
- [ ] 3.4 Port RUES protocol handling (session ID, block subscription)
- [ ] 3.5 Implement block event parsing and result construction
- [ ] 3.6 Create plugin manifest (`plugin.yaml`) with WebSocket capability
- [ ] 3.7 Add TinyGo build configuration and Makefile

## 4. Agent Code Removal

- [ ] 4.1 Remove `pkg/agent/dusk_service.go` and `dusk_service_test.go`
- [ ] 4.2 Remove dusk initialization from `pkg/agent/server.go`
- [ ] 4.3 Remove dusk config application from `pkg/agent/push_loop.go`
- [ ] 4.4 Remove `pkg/checker/dusk/` directory entirely
- [ ] 4.5 Update `pkg/agent/BUILD.bazel` to remove dusk dependencies

## 5. Control Plane Updates

- [ ] 5.1 Remove `DuskCompiler` from agent config compilers
- [ ] 5.2 Update `DuskProfile` to generate plugin assignments
- [ ] 5.3 Remove dusk-specific fields from agent config proto
- [ ] 5.4 Regenerate proto stubs

## 6. Testing

- [ ] 6.1 Unit test WebSocket SDK wrapper
- [ ] 6.2 Unit test agent WebSocket host functions
- [ ] 6.3 Integration test: plugin connects to mock Dusk node
- [ ] 6.4 End-to-end test: control plane assigns plugin, agent executes, gateway receives status

## 7. Documentation

- [ ] 7.1 Update dusk monitoring docs with plugin-based setup
- [ ] 7.2 Add dusk-checker as SDK example
