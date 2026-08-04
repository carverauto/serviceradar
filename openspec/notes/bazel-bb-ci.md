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

Vision

Build all of the repo via a Bazel and migrate CI to Bazel RBE and remote cache.  

A Bazel CI Workflow would look like this:

# Setup Docker Authenticate
bazel run -c opt //:buildbuddy_setup_docker_auth --verbose_failures

# 1 Build
bazel build -c opt //... --config=remote

# 2 Unit tests 
bazel test -c opt //... --config=remote --test_tag_filters=-integration_test,-acceptance_test

# Integration setup
bazel test -c opt //rust/integration-db:sweep_stale_dbs   --config=remote --test_tag_filters= --//build:enable_integration_tests

bazel test -c opt //elixir/serviceradar_core:migrate_template --config=remote --test_tag_filters= --//build:enable_integration_tests

bazel test -c opt //rust/integration-db:provision_db   --config=remote --test_tag_filters= --//build:enable_integration_tests

# Integration run tests
bazel test -c opt //... --config=remote --test_tag_filters=integration_test,-acceptance_test --//build:enable_integration_tests

// Add more integration tests here that require the DB fixture

# Integration teardown 
bazel test -c opt //rust/integration-db:teardown_db --config=remote --test_tag_filters= --//build:enable_integration_tests

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

