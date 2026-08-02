Reality

Bazel builds and tests 
- Go source tree
- Rust source tree 
- Only parts of the elixir tree

Known gaps
- Elixir is not yet fully build with Bazel
- Elixir Bazel integratin tests are not passing on CI
- Elixir Bazel images re-complile everythin instead of using the new bazel targets
- CI is a total mess


Vision

Build all of the repo via a Bazel and migrate CI to BuildBuddy Workflow  

A BuildBuddy Workflow would look like this:

# Setup Docker Authenticate
bazel run -c opt //:buildbuddy_setup_docker_auth --verbose_failures

# 1 build
bazel build -c opt //... --config=remote

# 2 unit tests 
bazel test -c opt //... --config=remote --test_tag_filters=-integration_test,-acceptance_test

# 3 integration / acceptance — name them, clear the filter
bazel test -c opt --config=remote --test_tag_filters=integration_test,-acceptance_test

# 4 images
bazel build -c opt //:images --config=remote

# 5 push
bazel run -c opt //:push --config=remote


Side effects
- BB remote build is leveraged througout
- BB remote cache is used consistently
- CI can replicate these steps and gain speedup from BB remote cache and build
- Most existing CI GH actions will be replaced with a single BB CI workflow

What must be true for the vision to become the new reality?

- The remaining Elixir targets must build and test via Bazel
- ALl Service Radar OCI images must use internal Bazel targets only
- zero scripts should be used unless explicistly permitted for hard corner cases. e.g. Docker Authentication.


Test tags: what actually exists (verified 2026-08-02)

The convention is EXCLUSION, not inclusion: tag only what must be run separately, and let
everything else fall into the default sweep. 

143 test targets outside //docker/images. Tags in use:

  manual                    13   the whole DB-backed tier: core integration_tests_s0..s7,
                                 migrate_template, the 3 //rust/integration-db lifecycle
                                 targets, banner_grab_integration_test
  no-remote-exec            12   same set minus banner_grab; cannot run on RBE
  external                   4   migrate_template + the 3 integration-db targets (disables
                                 test caching; a cached "pass" would provision nothing)
  integration_test           1   //rust/dgraph-client/tests:acceptance_tests_dgraph_container_test_test
  acceptance_test            1   (same target)
  dgraph_acceptance_test     1   (same target)
  restrict_acceptance_tests  1
  no-sandbox                 1

=> The remaining 130 targets are untagged and become the default sweep for free. Zero new
   tagging is required to adopt the scheme above.

=> The default sweep is fully RBE-safe: every `no-remote-exec` target is also `manual`, so
   none of them reach the remote sweep.

Note `manual` already excludes targets from `//...` wildcard expansion, so `-manual` in the
filter is redundant-but-explicit. The inverse matters more: any step that WANTS a manual
target must name it AND pass an empty `--test_tag_filters=`, or it resolves to nothing.
- no action in the image graph reaches the network; all deps are declared inputs.