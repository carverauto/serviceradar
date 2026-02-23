# God View Runtime Model

This folder uses a strict runtime composition model:

- State access: `this.state.*`
- Cross-engine dependencies: `this.deps.*`
- Same-engine method calls: `this.<methodName>(...)`

Do not use flat runtime fields such as `this.lastGraph` or `this.zoomMode`.
Do not import `./runtime_refs` (removed).

## Engine Ownership

- Layout methods: `layout_*_methods.js`
- Rendering methods: `rendering_*_methods.js`
- Lifecycle methods: `lifecycle_*_methods.js`

Renderer composition happens in:

- `js/lib/GodViewRenderer.js`
- `js/lib/god_view/renderer_deps.js`

## Guard Rails

These tests enforce structure and dependency discipline:

- `runtime_access_contract.test.js`
  - Ensures method files use `this.state` / `this.deps`
  - Rejects deprecated `runtime_refs` imports
- `deps_injection_contract.test.js`
  - Ensures every `this.deps.*` usage is declared in injected deps
  - Ensures no dead/unused dep declarations remain

If you add or remove cross-engine calls, update `renderer_deps.js` and keep both contract tests green.

## Add-a-Method Checklist

1. Add or update the method in the correct engine file (`layout_*`, `rendering_*`, or `lifecycle_*`).
2. Use only:
   - `this.state.*` for state
   - `this.deps.*` for cross-engine calls
   - `this.<methodName>(...)` for same-engine calls
3. If you add/remove a cross-engine dependency, update `renderer_deps.js`.
4. Run quick checks:
   - `bun run lint:god_view`
   - `bun run test:god_view:contracts`
   - `bun run typecheck:god_view`
5. Run full checks before merge:
   - `bun run test`
   - repo-level `make lint` and `make test` when touching shared paths

## Optional Git Hook

To run the fast God View checks on every commit when staged changes include `god_view` files:

```bash
git config core.hooksPath .githooks
```

Hook path:

- `.githooks/pre-commit`
