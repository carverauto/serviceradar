# GitHub Copilot Custom Instructions for OneIO

## Project Overview
OneIO is a Rust library providing unified IO operations for reading and writing compressed files from local and remote sources with both synchronous and asynchronous support.

## Code Quality Standards

### Before Committing - Always Run:
1. **Format code**: `cargo fmt`
2. **Run linter**: `cargo clippy --all-features` and fix all warnings
3. **Update README if lib.rs docs changed**: `cargo readme > README.md`
4. **Update CHANGELOG.md**: Add entries under `[Unreleased]` section
5. **Run tests**: `cargo test --all-features`

### Formatting Rules
- Always run `cargo fmt` before completing any task
- Fix all clippy warnings with `cargo clippy --all-features -- -D warnings`
- No trailing whitespace
- Follow Rust standard formatting conventions

### Documentation Requirements
- When modifying `src/lib.rs` documentation, always regenerate README:
  ```bash
  cargo readme > README.md
  ```
- Keep documentation examples up-to-date
- Add doc comments for all public APIs
- Include usage examples in module-level documentation

### Changelog Requirements
- **Always update CHANGELOG.md** when making changes
- Add entries under the `[Unreleased]` section
- Use proper formatting:
  - `### Added` - for new features
  - `### Changed` - for changes in existing functionality
  - `### Deprecated` - for soon-to-be removed features
  - `### Removed` - for now removed features
  - `### Fixed` - for bug fixes
  - `### Security` - for security fixes
- Be specific and clear about what changed
- Include context for why changes were made when relevant

## Commit and PR Guidelines

### Commit Messages
- Use imperative mood: "Add feature" not "Added feature"
- First line: concise summary (50 chars or less)
- **NO EMOJIS** in commit messages or PR descriptions
- Add blank line, then detailed explanation if needed
- Reference issues when applicable (e.g., "Fixes #123")

### Pull Requests
- **NO EMOJIS** in PR titles or descriptions
- Use clear, professional language
- Include sections: Summary, Changes, Testing
- List all integration points and breaking changes
- Provide code examples for new features

## Testing Requirements

### Test with Multiple Feature Combinations
```bash
# Default features
cargo test

# All features
cargo test --all-features

# No default features
cargo test --no-default-features

# Specific feature combinations
cargo test --features https,s3
cargo test --features http,gz,bz
```

### Before Finalizing
- Run `cargo clippy --all-features` and fix all issues
- Verify all tests pass with different feature flags
- Check documentation builds: `cargo doc --no-deps --all-features`
- Run examples if relevant: `cargo run --example <name> --features <required>`

## Feature Structure

### Available Features
- **Compression**: `gz`, `bz`, `lz`, `xz`, `zstd`
- **Protocols**: `http`, `https`, `ftp`, `s3`
- **TLS**: `rustls`, `native-tls` (mutually exclusive)
- **Additional**: `async`, `json`, `digest`, `cli`

### Feature Guidelines
- Use `#[cfg(feature = "...")]` for feature-gated code
- Test feature combinations to avoid conflicts
- Document feature requirements in examples
- Keep feature flags orthogonal when possible

## Code Style Preferences

### Error Handling
- Use `OneIoError` enum for all errors
- Provide clear error messages
- Use `?` operator for error propagation
- Add context to errors when relevant

### Module Organization
- Keep modules focused and cohesive
- Use `pub(crate)` for internal APIs
- Export public APIs through `lib.rs`
- Group related functionality in submodules

### Thread Safety
- All public APIs should be thread-safe where applicable
- Use proper synchronization primitives
- Document thread-safety guarantees
- Test concurrent usage patterns

## CI/CD Structure

### Workflow Jobs
1. **format**: Fast formatting check (independent)
2. **check**: Compilation with different features
3. **clippy**: Linting with strict warnings
4. **build**: Various feature combination builds
5. **test**: Comprehensive test suite

### CI Requirements
- All jobs must pass before merge
- Format check fails on `cargo fmt --check` errors
- Clippy fails on any warnings (`-D warnings`)
- Tests must pass with all feature combinations

## Common Patterns

### Adding New Features
1. Add feature flag to `Cargo.toml`
2. Implement feature-gated code with `#[cfg(feature = "...")]`
3. Add tests for the feature
4. Document in lib.rs and regenerate README
5. Update CHANGELOG.md
6. Add example if applicable

### Modifying Public APIs
1. Consider backward compatibility
2. Update all call sites
3. Update documentation and examples
4. Add migration guide if breaking
5. Update version in CHANGELOG.md

### Adding Dependencies
1. Use minimal feature flags
2. Make dependencies optional when possible
3. Document why the dependency is needed
4. Test build without default features

## Specific to OneIO

### Crypto Provider Initialization
- Always call `crypto::ensure_default_provider()` in HTTPS/S3/FTP paths
- Prefer AWS-LC with fallback to ring
- Make initialization idempotent and thread-safe
- Handle "already installed" cases gracefully

### Remote Operations
- Use `get_protocol()` to detect URL schemes
- Handle all error cases with clear messages
- Support custom HTTP clients
- Test with actual remote files when possible

### Compression
- Auto-detect compression from file extension
- Support all declared compression formats
- Test with actual compressed files
- Handle decompression errors gracefully

## Remember
- Quality over speed - take time to get it right
- Test thoroughly with different features
- Document changes clearly
- **Always run cargo fmt and cargo clippy before committing**
- **Always update CHANGELOG.md with changes**
- **No emojis in commits or PRs**
- **Regenerate README.md when lib.rs docs change**
