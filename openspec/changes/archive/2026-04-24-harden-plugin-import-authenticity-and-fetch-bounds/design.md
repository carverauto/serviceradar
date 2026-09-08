## Design

### Uploaded plugin signatures
The current `signature` map is not trustworthy. In strict mode (`allow_unsigned_uploads: false`), uploaded packages will need a verifiable signature envelope tied to the actual manifest and WASM blob.

The implementation should:
- define a canonical signed payload based on manifest plus content hash
- verify that payload against a configured trusted public-key set
- persist verified signer metadata separately from raw signature input
- fail closed when strict mode is enabled but no trusted signer configuration exists

### GitHub download bounds
GitHub manifest and WASM downloads will stream through a size-limited accumulator or temp file, aborting once `Storage.max_upload_bytes/0` is exceeded.

### GitHub token trust boundary
Authenticated import must not act as a confused deputy. If a GitHub token is configured, it may only be used for explicitly trusted repositories or owners. Requests outside that trust boundary must be rejected or performed unauthenticated, depending on policy.

### Manifest/ref/path hardening
Importer inputs should be normalized to safe GitHub refs and repo-relative paths. Manifest parsing should reject oversized/hostile YAML constructs instead of allowing unbounded alias expansion.
