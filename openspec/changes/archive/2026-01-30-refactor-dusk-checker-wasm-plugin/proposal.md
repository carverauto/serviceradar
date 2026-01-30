# Change: Refactor Dusk Checker to WASM Plugin

## Why

The dusk checker is currently embedded directly in `serviceradar-agent`, which was an expedient choice but has proven problematic:

1. **Coupling**: Updates to dusk checker logic require rebuilding and redeploying the entire agent
2. **Bloat**: Agents not monitoring Dusk nodes still carry the code
3. **Inconsistency**: The WASM plugin system exists and works, but dusk remains a special-case embedded checker
4. **Maintenance**: The embedded pattern (`pkg/agent/dusk_service.go`) duplicates concerns already solved by the plugin runtime

The WASM plugin system (spec: `wasm-plugin-system`) provides sandboxed execution, dynamic loading, and a standardized SDK. Moving dusk to this model aligns with the project's architecture direction.

## What Changes

### Removed
- **BREAKING**: `pkg/agent/dusk_service.go` and all dusk-specific code in `pkg/agent/`
- **BREAKING**: `pkg/checker/dusk/` directory (core checker logic moves to plugin)
- **BREAKING**: Elixir `DuskCompiler` in `lib/serviceradar/agent_config/compilers/dusk_compiler.ex`
- **BREAKING**: Proto fields for dusk config in `AgentConfigResponse`

### Added
- New standalone WASM plugin: `dusk-checker` using `serviceradar-sdk-go`
- Plugin manifest (`plugin.yaml`) with WebSocket capability declarations
- Plugin source in new repository or `plugins/dusk-checker/` directory

### Modified
- Agents receiving dusk monitoring assignments will load the plugin package instead of using embedded code
- `DuskProfile` resource continues to exist but drives plugin assignment rather than embedded config

## Impact

- **Affected specs**: `wasm-plugin-system` (WebSocket host function additions), `dusk-checker` (new spec)
- **Affected code**:
  - `pkg/agent/` - Remove dusk service, server integration, push loop config application
  - `pkg/checker/dusk/` - Remove entirely
  - `elixir/serviceradar_core/lib/serviceradar/agent_config/compilers/` - Remove dusk compiler
  - `proto/agent/` - Remove dusk-specific config fields
  - `serviceradar-sdk-go` - Add WebSocket host function wrappers

## References

- GitHub Issue: #2503
- Depends on: #2545 (plugin SDK improvements)
- SDK: https://github.com/carverauto/serviceradar-sdk-go
