# Repo conventions for Claude Code

This file is read on every Claude Code session in this repo. Keep it short and only include things that aren't obvious from the source or already documented in `CONTRIBUTING.md`.

## Git commits

- Do **not** add a `Co-Authored-By: Claude ...` trailer to commit messages.
- Do **not** add any "Generated with Claude Code" line to commit bodies or PR descriptions.
- Use Conventional Commit prefixes: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `perf:`, `chore:`, `style:`.
- Never bypass the pre-commit hook with `--no-verify` — fix the underlying issue.

## Validation

- Canonical "did I break anything" command: `./scripts/check-all.sh`. Runs the same 7 checks CI runs (fmt, clippy, build, test, doc tests, README sync, bench compile). Prefer this over running each step piecemeal.
- Clippy must pass with `cargo clippy --all --all-features -- -D warnings` (warnings are denied — stricter than `cargo clippy --all`).
- Do not run `cargo bench` unless explicitly asked. CI only checks bench compilation, and a full run is slow.

## Snapshot tests (insta)

- Snapshot files live in `src/snapshots/*.snap` and are managed by `cargo insta`.
- When a snapshot test fails because output formatting changed legitimately, run `cargo insta review` (or `cargo insta accept` after eyeballing the diff). Do not hand-edit `.snap` files.

## Documentation

- The crate-level rustdoc is generated from `README.md` via `#![doc = include_str!("../README.md")]` in `src/lib.rs` — README.md IS the crate's top-level docs, and code blocks in it run as doc tests under `cargo test --doc`.
- `./scripts/check-readme-sync.sh` enforces structural sync; run it after touching docs.
- When adding examples to README.md, make sure they compile, or mark them `ignore`/`no_run` deliberately.

## Code constraints

- Crate forbids `unsafe` (`#![forbid(unsafe_code)]` in `src/lib.rs`). Do not add `unsafe` blocks.
- MSRV is 1.88, edition 2024 (see `Cargo.toml`). Don't reach for language features that exceed this.
- Public API changes ripple into `examples/*.rs` and `fuzz/fuzz_targets/` — both compile in CI, so update them when renaming or changing exported types.
