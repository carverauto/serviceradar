# Contributing to netflow_parser

Thank you for your interest in contributing to netflow_parser! This document provides guidelines and workflows for contributors.

## Table of Contents

- [Development Setup](#development-setup)
- [Documentation Guidelines](#documentation-guidelines)
- [Testing](#testing)
- [Code Quality](#code-quality)
- [Submitting Changes](#submitting-changes)

## Development Setup

### Prerequisites

- Rust stable (latest version recommended)
- Git

### Clone and Build

```bash
git clone https://github.com/mikemiles-dev/netflow_parser.git
cd netflow_parser
cargo build
cargo test
```

### Install Git Hooks (Recommended)

We provide Git hooks to help catch issues before committing:

```bash
./scripts/install-hooks.sh
```

This installs a pre-commit hook that:
- Runs doc tests when documentation files are modified
- Reminds you to sync README.md and src/lib.rs

## Documentation Guidelines

**Important**: We maintain documentation in two places that must stay synchronized:

1. **`src/lib.rs`** - Rust doc comments (source of truth for rustdoc)
2. **`README.md`** - GitHub README (for crates.io and repository visibility)

### Updating Documentation

When updating documentation, follow this workflow:

#### 1. Edit `src/lib.rs` First

Make your documentation changes in the Rust doc comments:

```rust
//! ## Your Section
//!
//! Your documentation here...
//!
//! ```rust
//! // Your example code
//! ```
```

#### 2. Mirror Changes to `README.md`

Copy the same content to README.md (without the `//!` prefix):

```markdown
## Your Section

Your documentation here...

```rust
// Your example code
```
```

#### 3. Test Documentation

Run doc tests to ensure all examples compile:

```bash
cargo test --doc
```

#### 4. Verify Sync

Run the sync checker:

```bash
./scripts/check-readme-sync.sh
```

This script:
- ✓ Runs doc tests
- ✓ Compares section headers
- ✓ Checks for common sync issues
- ✓ Verifies Table of Contents

### Documentation Best Practices

- **Keep Examples Minimal**: Show only what's necessary to demonstrate the feature
- **Test Examples**: All code examples must compile (use doc tests)
- **Use `ignore` tag sparingly**: Only for pseudo-code or incomplete examples
- **Update Table of Contents**: When adding new sections, update the TOC in README.md
- **Section Order**: Keep sections in the same order in both files

### Documentation Structure

Both `src/lib.rs` and `README.md` should follow this structure:

1. Example
2. Serialization (JSON)
3. Filtering for a Specific Version
4. Iterator API
5. Parsing Out Unneeded Versions
6. Error Handling Configuration
7. Netflow Common
8. Re-Exporting Flows
9. Template Cache Configuration
10. V9/IPFIX Notes
11. Performance & Thread Safety
12. Features
13. Included Examples

## Testing

### Run All Tests

```bash
cargo test
```

### Run Only Doc Tests

```bash
cargo test --doc
```

### Run Specific Test

```bash
cargo test test_name
```

### Benchmarks

Run all benchmarks (excluding feature-gated benchmarks):

```bash
cargo bench
```

Run all benchmarks including `netflow_common_bench` (requires `netflow_common` feature):

```bash
cargo bench --all-features
```

Run a specific benchmark:

```bash
# Standard benchmarks (no features required)
cargo bench --bench netflow_parser_bench
cargo bench --bench netflow_v5_bench
cargo bench --bench netflow_v9_bench
cargo bench --bench netflow_ipfix_bench
cargo bench --bench packet_size_bench

# Feature-gated benchmark (requires netflow_common feature)
cargo bench --bench netflow_common_bench --features netflow_common
```

## Code Quality

### Formatting

We use `rustfmt` for code formatting:

```bash
cargo fmt
```

### Linting

We use `clippy` for additional linting:

```bash
cargo clippy --all
```

### Before Committing

Ensure these pass:

```bash
cargo fmt --check
cargo clippy --all
cargo test
cargo test --doc
./scripts/check-readme-sync.sh
```

Or use the pre-commit hook (recommended):

```bash
./scripts/install-hooks.sh
```

## Submitting Changes

### Pull Request Process

1. **Fork the repository** and create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following the guidelines above

3. **Test thoroughly**:
   ```bash
   cargo test
   cargo test --doc
   cargo clippy --all
   ./scripts/check-readme-sync.sh
   ```

4. **Commit your changes**:
   ```bash
   git add .
   git commit -m "feat: description of your changes"
   ```

   Use conventional commit messages:
   - `feat:` - New features
   - `fix:` - Bug fixes
   - `docs:` - Documentation changes
   - `test:` - Test additions/changes
   - `refactor:` - Code refactoring
   - `perf:` - Performance improvements

5. **Push to your fork**:
   ```bash
   git push origin feature/your-feature-name
   ```

6. **Create a Pull Request** on GitHub

### What to Include in Your PR

- Clear description of changes
- Motivation/reasoning for changes
- Any breaking changes highlighted
- Tests for new functionality
- Updated documentation (both lib.rs and README.md)

### CI Checks

Your PR must pass these automated checks:

- ✓ `cargo fmt --check` - Code formatting
- ✓ `cargo clippy --all` - Linting
- ✓ `cargo build` - Compilation
- ✓ `cargo test` - Unit tests
- ✓ `cargo test --doc` - Documentation tests
- ✓ `./scripts/check-readme-sync.sh` - Documentation sync
- ✓ `cargo bench` - Benchmarks

## Automated Tooling

### Scripts

We provide several helper scripts in `scripts/`:

- **`check-readme-sync.sh`** - Verifies README.md and src/lib.rs are in sync
- **`install-hooks.sh`** - Installs Git pre-commit hooks
- **`pre-commit`** - Pre-commit hook (checks doc tests)

### CI/CD

GitHub Actions automatically runs all checks on:
- Every push to `main` branch
- Every pull request to `main` branch

See `.github/workflows/rust.yml` for details.

## Getting Help

- **Issues**: Open an issue on GitHub for bugs or feature requests
- **Discussions**: Use GitHub Discussions for questions
- **Documentation**: Check the [README](README.md) and rustdoc

## Code of Conduct

Be respectful and constructive in all interactions. We're here to build great software together!

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.

---

Thank you for contributing to netflow_parser! 🎉
