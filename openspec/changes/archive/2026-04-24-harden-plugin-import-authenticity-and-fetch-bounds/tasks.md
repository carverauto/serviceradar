## 1. Implementation
- [x] 1.1 Replace upload signature presence checks with cryptographic verification in strict mode.
- [x] 1.2 Stream and size-cap GitHub manifest/WASM downloads during import.
- [x] 1.3 Restrict authenticated GitHub import to trusted repositories or owners.
- [x] 1.4 Validate GitHub ref/path inputs and harden manifest parsing against hostile YAML.

## 2. Verification
- [x] 2.1 Add focused tests for strict upload signature verification.
- [x] 2.2 Add focused tests for oversized GitHub download rejection.
- [x] 2.3 Add focused tests for GitHub token trust-boundary enforcement.
- [x] 2.4 Add focused tests for ref/path validation and hostile manifest rejection.
- [ ] 2.5 Run `mix compile` in `elixir/web-ng` and the focused plugin-import test targets.
