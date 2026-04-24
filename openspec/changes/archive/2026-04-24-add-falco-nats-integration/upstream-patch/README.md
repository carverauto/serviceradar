# Upstream Falcosidekick Patch

These patch files document the minimal changes needed in
[falcosecurity/falcosidekick](https://github.com/falcosecurity/falcosidekick) to support
`.creds` file and custom CA certificate for NATS output.

## Files Changed

| File | Description |
|------|-------------|
| `types/types.go` | Add `CredsFile` and `CaCertFile` fields to `natsOutputConfig` |
| `config.go` | Add Viper defaults for `NATS.CredsFile` and `NATS.CaCertFile` |
| `outputs/nats.go` | Build `[]nats.Option` with `nats.UserCredentials()` and `nats.RootCAs()` |
| `config_example.yaml` | Add commented fields to the `nats:` block |
| `docs/outputs/nats.md` | Add rows to config table and update YAML example |

## Environment Variables

Viper's `SetEnvKeyReplacer` maps these automatically:

- `NATS.CredsFile` -> `NATS_CREDSFILE`
- `NATS.CaCertFile` -> `NATS_CACERTFILE`

## Status

These patches should be submitted as a PR to `falcosecurity/falcosidekick`.
Until merged upstream, use our fork with these changes applied.
