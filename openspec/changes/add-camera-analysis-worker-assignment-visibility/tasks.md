## 1. Runtime Visibility
- [ ] 1.1 Add a worker-assignment snapshot derived from the active analysis dispatch runtime.
- [ ] 1.2 Track assignment open/close so per-worker counts stay current.
- [ ] 1.3 Keep assignment visibility bounded and ephemeral rather than persisting it in the worker registry.

## 2. Management Surface
- [ ] 2.1 Expose per-worker assignment counts and bounded active assignments through the worker management API.
- [ ] 2.2 Show assignment visibility in the `web-ng` camera analysis worker ops surface.

## 3. Verification
- [ ] 3.1 Add focused tests for assignment tracking and API/UI exposure.
- [ ] 3.2 Validate the change with `openspec validate add-camera-analysis-worker-assignment-visibility --strict`.
