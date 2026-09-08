# KV Regression Safeguards (Deprecated)

KV-backed service configuration has been removed. This plan is no longer applicable because services now load configuration from local files or gRPC-delivered config, and no services seed/watch KV for configuration.

If you need CI safeguards for configuration, update tests and workflows to validate on-disk config templates, pinned overlays, and gRPC-delivered configs instead of KV state.
