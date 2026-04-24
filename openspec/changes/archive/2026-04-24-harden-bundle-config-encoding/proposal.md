## Why
Bundle generators still have two config-encoding trust gaps:
- bootstrap YAML uses manual string quoting and can be broken by backslash-heavy input
- OTel collector TOML interpolates `server.port` directly instead of encoding/coercing it

The tempfile/symlink issue reported alongside this is already fixed by `TempArchive`, so this change only covers the remaining live config injection paths.

## What Changes
- replace manual YAML string escaping in edge bootstrap bundle generation with a safe encoder
- ensure OTel collector `server.port` is encoded/coerced safely before inclusion in TOML
- add focused regressions for YAML and TOML injection attempts

## Impact
- closes bundle configuration injection vectors without changing bundle format semantics
- preserves existing operator/dev workflows
