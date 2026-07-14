# Development Scripts

This directory contains scripts to help maintain code quality and documentation sync.

## Available Scripts

### `check-all.sh`

Runs all quality checks that CI will run. Use this before committing/pushing.

```bash
./scripts/check-all.sh
```

**Checks:**
1. Code formatting (`cargo fmt --check`)
2. Clippy lints (`cargo clippy --all`)
3. Build (`cargo build`)
4. Unit tests (`cargo test`)
5. Doc tests (`cargo test --doc`)
6. README sync (`./scripts/check-readme-sync.sh`)
7. Benchmarks compile (`cargo bench --no-run`)

**Exit codes:**
- `0` - All checks passed
- `1` - One or more checks failed

---

### `check-readme-sync.sh`

Verifies that README.md and src/lib.rs documentation are in sync.

```bash
./scripts/check-readme-sync.sh
```

**Checks:**
1. Doc tests compile and pass
2. Section headers match between files
3. No common sync issues (code block counts, TODOs, etc.)
4. Table of Contents exists

**Note:** Some differences are expected (e.g., README has Table of Contents, lib.rs doesn't).

---

### `install-hooks.sh`

Installs Git pre-commit hooks.

```bash
./scripts/install-hooks.sh
```

**Installs:**
- Pre-commit hook that runs doc tests when documentation files are modified
- Reminds you to sync README.md and src/lib.rs

**To uninstall:**
```bash
rm .git/hooks/pre-commit
```

**To bypass hooks (not recommended):**
```bash
git commit --no-verify
```

---

### `pre-commit`

Git pre-commit hook (installed by `install-hooks.sh`).

**Triggers when:**
- `README.md` or `src/lib.rs` are being committed

**Actions:**
- Runs doc tests
- Reminds about syncing documentation files

---

## Typical Workflows

### Before Committing

Run all checks:
```bash
./scripts/check-all.sh
```

Or just check documentation sync:
```bash
./scripts/check-readme-sync.sh
```

### Setting Up Your Dev Environment

Install pre-commit hooks:
```bash
./scripts/install-hooks.sh
```

### After Updating Documentation

1. Edit `src/lib.rs` doc comments
2. Mirror changes to `README.md`
3. Run checks:
   ```bash
   cargo test --doc
   ./scripts/check-readme-sync.sh
   ```

## CI/CD Integration

These scripts are integrated into the GitHub Actions workflow (`.github/workflows/rust.yml`):

- `check-readme-sync.sh` - Runs on every PR
- All checks from `check-all.sh` - Run on every push to main and every PR

## Maintenance

If you need to modify these scripts:

1. Test thoroughly
2. Update this README if behavior changes
3. Update CONTRIBUTING.md if workflow changes
4. Ensure CI workflow still works

## Questions?

See [CONTRIBUTING.md](../CONTRIBUTING.md) for more details on the development workflow.
