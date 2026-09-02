# Continuous Development with Bazel Remote

## Prerequisites

Ensure that:

- Bazelisk is installed.
- A BuildBuddy API key is present in `.bazelrc.remote`; the file is ignored by
  Git.
- A C compiler (GCC or Clang) is installed.

## Basic concept

Instead of building and testing locally, Bazel streams the source code to
a remote build cluster with a cache and only compiles and tests the difference
compared to the previous cached build. The resulting artifacts are written back
into the remote cache. The remote cache is shared between remote dev workstations,
the GH Action runners, and the BB CI workflow. 

## Inner Dev Loop

It is generally recommended to build and test only the source tree one is working on.
For example, working on the Golang source tree leads to:

```bash
bazel build -c opt --config=ci //go/...

bazel test -c opt --config=ci //go/...
```


For even more specific targets, use the file path. For example:

```bash
bazel build -c opt --config=ci //elixir/serviceradar_core/...
```

Note that the trailing three dots simply mean "anything" below this path. Also note that Bazel 
picks up all changes in dependencies automatically and compiles the difference to the 
previous build.

Building sub-targets may cause upstream targets to rebuild in case of a
full repo rebuild. However, it is common to skip the full rebuild until 
the local work has been completed.

When ready to open a PR, update the branch explicitly and then run the standard
gates:

```bash
git fetch origin
git rebase origin/staging
make lint
make test
```

Keep the rebase separate from validation. Test commands must not pull or merge
Git history implicitly. `make test` invokes the repository's Bazel test graph
with the same BuildBuddy-backed CI profile used by the main build workflow.
Run a focused Go race test when the changed package needs one, for example:

```bash
bazel test -c opt --config=ci //go/pkg/... \
  --@io_bazel_rules_go//go/config:pure=false \
  --@io_bazel_rules_go//go/config:race
```

Depending on the scope of local changes, these gates may take a few minutes.
Bazel build and test progress is streamed to the same BuildBuddy cluster used
by CI.

The build progress can be tracked in the BB dashboard:

https://carverauto.buildbuddy.io

When ready, open a PR from a feature branch and follow the CI checks.


## Outer Dev Loop

GitHub Actions owns lint, integration, and repository policy workflows. The root
`buildbuddy.yaml` workflow and GitHub Actions main build both use the shared
BuildBuddy cache and remote execution cluster for Bazel compilation and
eligible tests. Database-backed test actions are the intentional exception:
their compile actions remain remote, while each mutable DB `TestRunner` is
placed on the workflow runner with the explicit local lifecycle contract.
