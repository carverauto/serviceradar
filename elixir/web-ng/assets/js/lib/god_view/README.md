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
