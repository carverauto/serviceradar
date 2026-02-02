## 1. Core Service Updates
- [ ] 1.1 Verify and fix `interval` field population in `SweepJob` to `AgentConfig` mapping.
- [ ] 1.2 Ensure `SweepProfile` defaults are correctly applied when `SweepJob` does not override them.
- [ ] 1.3 Add unit tests to verify `interval` propagation in the config compiler.

## 2. Agent Updates
- [ ] 2.1 Verify `dusk-agent` reads and respects the `interval` field from the received JSON config.
- [ ] 2.2 Ensure the agent does not fallback to a hardcoded 5-minute default if a valid interval is provided.
- [ ] 2.3 Add logging to the agent to indicate the effective sweep interval being used.

## 3. Validation
- [ ] 3.1 Verify end-to-end that a 6-hour interval setting results in a 6-hour scan cycle (not 5 minutes).
