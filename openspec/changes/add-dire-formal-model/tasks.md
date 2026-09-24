# Tasks

## 1. TLC toolchain (PR 1)

- [x] 1.1 Pin `tla2tools.jar` as an `http_file` with sha256 in `MODULE.bazel`; add the
      `rules_java` `bazel_dep` for the remote JDK.
- [x] 1.2 `//build/tla:tlc` `java_binary` (`main_class = "tlc2.TLC"`).
- [x] 1.3 Run TLC once on a passing and a violating spec; copy the exact result lines and
      exit statuses before writing the parser.
- [x] 1.4 `//build/tla:tlc.bzl` `tlc_test` macro and `py_test` driver with
      `expect = "pass" | "violation:<Property>"`.
- [x] 1.5 `//build/tla/selftest`: one pass config, one deliberate-violation config, and a
      driver unit test showing a wrong-property violation and an unexpected pass both fail.
- [x] 1.6 `bazel test --config=remote //build/tla/...` and `make test` green.

## 2. DIRE model (PR 2)

- [x] 2.1 `formal/dire/DireLifecycle.tla`: state, actions citing their Elixir functions,
      invariants and action properties per design D4.
- [x] 2.2 `goal`, `current`, `vacuity` and one `witness_<switch>` configuration per switch
      (resolution and lifecycle models).
- [x] 2.3 For each must-pass invariant, show once that a deliberately broken model variant
      violates it; record the result in the PR description, not the tree.
- [x] 2.4 Check each unconfirmed candidate from the design's risks section; add a switch and
      witness only for a counterexample confirmed in code.
- [x] 2.5 Every configuration finishes within the runtime budget; `make test` green.
- [ ] 2.6 After merge: file one GitHub issue per switch, citing its witness configuration and
      counterexample.

## 3. Trace validation (PR 3: resolution; PR 4: lifecycle)

- [x] 3.1 `test/support/dire_trace.ex` recorder: drives the real entry points in a synthetic
      world, records the full model state after every step, maps uids and identifiers to model
      names in first-seen order, and raises on anything it cannot map.
- [x] 3.2 `formal/dire/DireResolutionTrace.tla`: pins every variable to the logged state at
      every step; a matched trace violates `TraceIncomplete`.
- [x] 3.3 Self-test: one `__tamper_<var>` variant per model variable, each rejected by TLC.
- [x] 3.4 Resolution scenario traces (six), committed under `formal/dire/traces` and compared
      by the integration test; the model was corrected where the traces disagreed with it.
- [ ] 3.5 Lifecycle scenario traces (merge, unmerge, soft delete, revival paths, purge).
- [x] 3.6 Committed traces in the core integration runtime data; serial disposition rows;
      the scratch-database run and `make test` are green.

## 4. Close-out

- [x] 4.1 `formal/dire/README.md`: the switch, witness, promote loop.
- [ ] 4.2 Archive this change once all three PRs are merged.
