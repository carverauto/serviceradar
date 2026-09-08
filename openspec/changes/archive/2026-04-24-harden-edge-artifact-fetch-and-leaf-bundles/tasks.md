## 1. Implementation
- [x] 1.1 Rework release artifact mirroring to disable implicit redirect following and revalidate each redirect target.
- [x] 1.2 Stream mirrored artifact downloads with an enforced byte limit instead of buffering the full response body in memory.
- [x] 1.3 Make artifact basename extraction handle missing URL paths safely.
- [x] 1.4 Escape edge-site values safely in generated NATS leaf setup/readme shell content.

## 2. Verification
- [x] 2.1 Add focused tests for redirect revalidation and oversize artifact rejection in release artifact mirroring.
- [x] 2.2 Add focused tests for shell-safe edge-site setup script generation.
- [x] 2.3 Run `mix compile` and focused edge tests in `elixir/serviceradar_core`.
