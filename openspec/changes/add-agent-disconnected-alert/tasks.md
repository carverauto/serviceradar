## 1. Implementation

- [x] 1.0 Make `PublishStateChange` register its hook from `atomic/3` and read its keyword options.
- [x] 1.1 Seed the `agent_health_state_change_events` event rule and the managed `agent_disconnected` stateful rule.
- [x] 1.2 Record the `connected` transition in `register_connected`, with the previous state supplied by the check-in path.
- [x] 1.3 Tests: a disconnected agent transition opens one alert and a reconnect recovers it; a check-in from a disconnected agent records the transition.
- [x] 1.4 Run `openspec validate add-agent-disconnected-alert --strict`.
