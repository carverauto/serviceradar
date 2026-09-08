## Why
The current plugin import path still has four security gaps:
- uploaded package signatures are treated as presence-only metadata rather than cryptographic proof
- GitHub importer downloads buffer full remote bodies into memory before size enforcement
- any configured GitHub token is sent for any user-nominated GitHub repository, including private repos
- importer ref/path inputs and YAML parsing are not bounded tightly enough for hostile content

## What Changes
- require cryptographic verification for signed upload workflows when unsigned uploads are disabled
- stream and hard-cap GitHub manifest/WASM downloads during import
- restrict authenticated GitHub import to explicitly trusted repositories or owners
- validate and normalize GitHub ref/path inputs and harden manifest parsing against alias-expansion abuse

## Impact
- affects plugin upload/import security policy and the GitHub plugin importer
- may require operator configuration of trusted plugin signing keys and trusted GitHub repos before strict mode can be enabled
