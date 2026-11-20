# Change: Normalize vendor syslog with napalm-logs profiles

## Why

ServiceRadar accepts syslog from many network operating systems and stores the
raw body. It does not yet extract the vendor-agnostic fields those messages
carry (interface, BGP peer, alarm, user). The napalm-logs profile set already
encodes that extraction for ten platforms, and operators need it as something
they can install, upgrade, and turn off per tenant.

## What Changes

- Add a syslog profile document, converted from the napalm-logs YAML (and the
  one NX-OS Python parser) under
  `napalm_logs/config` at commit `1f7b06f808156812bab07d1c622fa1d0ba91f2d5`
  of <https://github.com/mfreeman451/napalm-logs>.
- Evaluate those profiles inside the existing Zen rule pipeline as one custom
  node, `syslog_profile`, implemented once in `rust/zen-normalize`. The log
  collector and core both compile rules through that crate, so both see the
  same match.
- Ship one built-in Solution Pack per platform. Each pack installs one
  `zen_rule` whose template is `syslog_profile` and whose `builder_config` is
  the profile. Pack install compiles that config into a self-contained JDM
  document and publishes it on the existing `logs.syslog` rule bundle.
- Leave unrecognized messages unchanged. A matched message stays a log. The
  raw body stays. Structured fields are added as log attributes.
- Prove the port against the napalm-logs `tests/config` corpus (133 raw
  messages).

This change does not add a new Solution Pack resource kind. Packs already
distinguish `stateful_alert_rule`, `event_rule`, and `zen_rule`. The new type
is a Zen rule template, which is the type those rules already have.

## Impact

- Affected specs: new `syslog-vendor-normalization`; added requirements on
  `solution-packs-catalog` and `observability-signals`.
- Affected code, when implemented: `rust/zen-normalize`, the Zen rule template
  compiler, Solution Pack validation and the built-in pack tree, syslog
  docs. The collector header parser and the `syslog_severity` / `cef_severity`
  rules stay as they are.
- Active change `improve-syslog-ingestion-fidelity` owns header detection,
  lossless fallback, and `source_ip`. This change starts after that parse and
  does not modify its requirements.
- No new database write path. Normalized fields ride the log record that
  already flows through JetStream and `event_writer`.
