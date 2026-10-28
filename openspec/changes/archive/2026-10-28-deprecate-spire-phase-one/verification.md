# Phase-one verification

## Executed

- Full `make test BAZEL_UNIT_TEST_FLAGS='-c opt --config=remote --test_output=errors'`: 409 targets passed, two Swift platform targets skipped. BuildBuddy invocation: https://carverauto.buildbuddy.io/invocation/00781053-5150-4316-a98c-29cc2d281bff . Includes Helm, Go/Rust, Elixir unit shards, formatting/Credo, registration and migration-version checks.
- Focused Helm, Go gRPC and Rust kvutil/trapd/flowgger/rperf targets: six passed in https://carverauto.buildbuddy.io/invocation/57eef47f-d823-4d1e-869c-203e8ccbbe52 . The final full run includes later account/authorization and CNPG hook assertions.
- Removing the Go startup warning fails both lowercase and uppercase SPIFFE factory cases: https://carverauto.buildbuddy.io/invocation/391d4fdb-45b9-48ea-9643-01b15130dd34 . That run's Helm failure was a missing declared render dependency and is not regression evidence.
- Restoring the former blank-mode SPIFFE fallback fails the Helm mTLS-default assertion: https://carverauto.buildbuddy.io/invocation/d74ade94-15cb-4854-a404-4a7e725859f0 . Both mutated production files were restored byte for byte before the full green run.
- `gofmt`, targeted `cargo fmt`, remote Elixir formatter, `git diff --check`, and `openspec validate deprecate-spire-phase-one --strict` passed.

## Pending or not run

- DB-backed web API creation, Ash creation and raw SQL default assertions require hosted DB integration CI on the published PR head. Unit shard loading is not counted as DB execution.
- Live SPIRE startup, deployment upgrade, certificate rotation, cluster migration, backup/restore and cleanup are untested. No live operational change was performed; the user confirmed no SPIRE users.
- Standalone Cargo checks/Clippy were not run locally under the remote-only rule. Hosted Rust checks remain required.
- JS CLI `:ci` is manual, local/no-remote and uses host npm, so it was not invoked on this machine. This change only adds help text; its existing mTLS creation default is unchanged.
- `//docs:lint` passes but is a placeholder, not a Docusaurus build. No docs site build is claimed.

## Documentation evidence

- Archify workflow deterministic delivery: 9/9 checks, no errors or warnings. Source SHA-256: 5962ae7887217b25a2fd67e512a18067c98e1fd5e5ce0fb35524a50439cb4a3e . HTML SHA-256: d5da858ac9ba2bdc89152d1fb0ef91b11d6cff2656ab438a76dd099f64560dde .
- Automated browser checks passed desktop containment at 1440x900, 1600x1000, 1920x1080 and 2048x1320, including light/dark evidence. Canonical receipt and screenshots are retained in docs/architecture.
- Image review inspected the 1440x900 dark and 2048x1320 light screenshots: labels and edges are readable and contained; the largest viewport retains extra lower whitespace. This is a separate visual observation, not a browser-test claim.
- Workflow viewer: https://agentboard.farm01.carverauto.dev/documents/122 . Approved portable OpenSpec review: https://agentboard.farm01.carverauto.dev/documents/123 . The user ended the local review session; it was not reopened.

## Shipping constraints

Phase one only. Retain load-bearing mTLS certificate URI identities and existing explicit compatibility. Do not merge. Retain the Treehouse lease through review and green CI. STOP immediately if either physical cwd or Git top-level differs from AGENTBOARD_SEAT_WORKTREE, the launcher check fails, or execution is in the primary checkout; report to the coordinator and block the live owned claim.
