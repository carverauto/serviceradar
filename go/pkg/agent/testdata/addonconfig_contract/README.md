# Add-on config contract fixtures (generated — do not edit by hand)

Each `<addon>.json` holds the exact `config_json` bytes core's delivery path
emits for a representative assignment of that bundled add-on (schema-coerced;
compatibility-form inputs already normalized). `rdp-adapter.json` is empty on
purpose: that add-on consumes no config and core delivers no bytes for it.

Regenerate after changing an add-on `config.schema.json`, the representative
params, or the delivery-path coercion rules:

    cd elixir/serviceradar_core
    mix serviceradar.gen.addon_contract_fixtures

Kept fresh by `test/serviceradar/edge/addon_config_contract_fixtures_test.exs`
(fails on drift) and decoded with the real agent/add-on decoders by
`go/pkg/agent/addon_config_contract_test.go` and the Rust contract tests in
`rust/anomaly-addon`, `rust/otel-addon`, `rust/workload-identity`.
See docs/docs/addon-config-contracts.md.
