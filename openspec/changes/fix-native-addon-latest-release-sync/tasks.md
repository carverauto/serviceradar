## 1. Catalog selection

- [x] 1.1 Select only the newest import-ready release during unattended sync
- [x] 1.2 Preserve exact historical selection when `release_tag` is supplied
- [x] 1.3 Add unit coverage for newest-release, explicit-release, and partial-release behavior

## 2. Immutable anomaly package repair

- [x] 2.1 Bump anomaly add-on manifest and Rust crate from 0.3.0 to 0.3.1
- [x] 2.2 Refresh Cargo lock/vendor inputs required by the native add-on release gate
- [x] 2.3 Verify the anomaly native add-on bundle and version-bump gates

## 3. Validation and rollout

- [x] 3.1 Run web-ng format, compile, strict Credo, and focused native add-on tests
- [x] 3.2 Run strict OpenSpec validation
- [ ] 3.3 Publish a feature branch and Forgejo PR linked to issue #4558
- [ ] 3.4 After release, verify demo scheduled sync converges without historical conflict retries
