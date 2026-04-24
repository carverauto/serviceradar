## Design

### YAML bootstrap config
`BundleGenerator` currently hand-rolls YAML string quoting. Since JSON scalars are valid YAML, string values will be emitted with `Jason.encode!/1` instead of ad hoc escaping.

### OTel TOML port
`CollectorBundleGenerator` will normalize the configured OTLP gRPC port to a positive integer, defaulting to `4317` when the override is absent or invalid. The resulting integer will then be encoded through the existing TOML encoder path.

### Tests
Focused tests will assert:
- backslashes and quotes remain inert in generated YAML
- newline-bearing OTLP port overrides do not inject extra TOML keys
