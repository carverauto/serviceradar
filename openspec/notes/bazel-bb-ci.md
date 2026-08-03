Reality

Bazel builds and tests 
- Go source tree
- Rust source tree 
- JS source tree
- Proto source tree
- The elixir source tree
- The bulk of OCI images

Known gaps 
- CI is a total mess

Step 1 of the vision below is green as of 2026-08-03: `bazel build -c opt //... --config=remote`
builds all 1,971 targets clean. Getting there needed no -c opt work at all -- every failure
was mode-independent and had been latent. See "Test tags" below for the two repo-level
causes (a scratch tree missing from .bazelignore, and `local` tags on targets whose exec
platform is Linux).

One environment-level cause is NOT a repo fix: a stale ghcr.io entry in the macOS keychain
makes rules_oci send a dead credential, and ghcr answers 403 where anonymous returns 200.
`docker logout ghcr.io` restores it. Large ghcr blob fetches (arc-runner) are also just
flaky over a slow link -- two attempts failed two different ways, a third succeeded.

Step 2 is green. One test is tagged `manual` and therefore out of the sweep:

  //scripts:release_publish_contracts_test        (RED when run explicitly)

It does not belong in a unit sweep in the first place. It is 665 lines of bash driving
embedded Python that makes literal substring assertions over CI configuration -- 5 .forgejo
workflow YAMLs, 9 release shell scripts, the image inventory, the ArgoCD app -- and
exercises no shipped code path. It was in the sweep only because it was untagged, which
under the exclusion convention below means "included by default".

Run it deliberately:

  bazel test //scripts:release_publish_contracts_test --test_tag_filters=

It is not stale and it is not flaky -- it is reporting real drift between the two release
workers. fa88629ca ("pin forgejo-ci digest for Wasm plugin publish") also loosened the
release-tag source gate in .forgejo/workflows/wasm-plugins.yml to let workflow_dispatch run
from a non-tag ref, and did not make the same change to native-addons.yml:

    native-addons.yml:97   if [[ "${GITHUB_REF}" != "${expected_ref}" ]]
    wasm-plugins.yml:97    if [[ "${GITHUB_EVENT_NAME}" != "workflow_dispatch" && ... ]]

The test asserts both gates stay identical (test-release-publish-contracts.sh:593); the
fragment loop just trips first. The bypass is bounded -- the dispatch path still requires
validate-release-tag.sh, a VERSION match, and the tag commit being an ancestor of staging;
only the run's ref may differ from the tag ref.

Deliberately NOT fixed: .forgejo/workflows/ is being replaced by BB workflows, so editing
those jobs is throwaway work. Whoever writes the replacement owns this decision -- either
the dispatch recovery path is intended and both workers should have it, or it is not and
wasm-plugins.yml should go back to the strict gate. Do not "fix" it by relaxing the
assertion in the contract test; that would rubber-stamp the drift.


Vision

Build all of the repo via a Bazel and migrate CI to BuildBuddy (BB) Workflow  

A BuildBuddy Workflow would look like this:

# Setup Docker Authenticate
bazel run -c opt //:buildbuddy_setup_docker_auth --verbose_failures

# 1 Build
bazel build -c opt //... --config=remote

# 2 Unit tests 
bazel test -c opt //... --config=remote --test_tag_filters=-integration_test,-acceptance_test

# 3 Integration / acceptance — name them, clear the filter
bazel test -c opt --config=remote --test_tag_filters=integration_test,-acceptance_test

# 4 Build images
bazel build -c opt //:images --config=remote

# 5 Push images to registry 
bazel run -c opt //:push --config=remote


Side effects
- BB remote build is leveraged throughout
- BB remote cache is used consistently
- CI can replicate these steps and gain speedup from BB remote cache and build
- Most existing CI GH actions will be replaced with a single BB CI workflow

What must be true for the vision to become the new reality?

- The remaining Elixir targets must build and test via Bazel
- ALl Service Radar OCI images must use internal Bazel targets only
- zero scripts should be used unless explicistly permitted for hard corner cases. e.g. Docker Authentication.


Test tags: what actually exists (re-verified 2026-08-03)

The convention is EXCLUSION, not inclusion: tag only what must be run separately, and let
everything else fall into the default sweep. 

150 test targets outside //docker/images. Tags in use:

  integration_test          10   core integration_tests_s0..s7, banner_grab_integration_test,
                                 and the dgraph acceptance target
  manual                     9   the DB-backed tier that cannot self-provision:
                                 migrate_template, the 3 //rust/integration-db lifecycle
                                 targets, the 2 //integration_tests/srql tests, 2 js :ci,
                                 plus //scripts:release_publish_contracts_test (a CI-config
                                 linter, not a unit test -- see above)
  no-remote                  8   (same shape)
  no-remote-exec             6   migrate_template, the 3 integration-db targets, the 2 srql
                                 tests; cannot run on RBE
  external                   4   migrate_template + the 3 integration-db targets (disables
                                 test caching; a cached "pass" would provision nothing)
  no-sandbox                 3
  acceptance_test            1   //rust/dgraph-client/tests:acceptance_tests_dgraph_container_test_test
  dgraph_acceptance_test     1   (same target)
  restrict_acceptance_tests  1

=> The remaining targets are untagged and become the default sweep for free. Zero new
   tagging is required to adopt the scheme above.

=> The default sweep is fully RBE-safe: every `no-remote-exec` target is also `manual`, so
   none of them reach the remote sweep.

The previous census (2026-08-02) predates commit f14be4eba, which moved core
integration_tests_s0..s7 off `manual` and onto `integration_test`. That is why `manual`
went 13 -> 8 while `integration_test` went 1 -> 10; nothing was untagged.

`local` is now used by ZERO test targets, and must stay that way.

If a test genuinely cannot run on RBE, tag it `manual` + `no-remote-exec` like the rest
  of the DB-backed tier. Never `local`.

Do not point //... at a tree Bazel should not own. `ctx/` is a local scratch dir (a
DeepCausality checkout and assorted logs); it is in .gitignore, which does NOT imply
.bazelignore. Until it was added there it contributed 1,185 analysis errors to
`bazel build //...` on a workstation while CI, which checks out clean, saw none.

Note `manual` already excludes targets from `//...` wildcard expansion, so `-manual` in the
filter is redundant-but-explicit. The inverse matters more: any step that WANTS a manual
target must name it AND pass an empty `--test_tag_filters=`, or it resolves to nothing.
- no action in the image graph reaches the network; all deps are declared inputs.