# Continuous Development with Bazel Remote

## Prerequisites

Ensure that
* Bazelisk is installed
* A BB API key is present in .bazelrc.remote and the file is gitignored
* A C compiler (GCC or Clang) is installed

## Basic concept

Instead of building and testing locally, Bazel streams the source code to
a remote build cluster with a cache and only compiles and tests the difference
compared to the previous cached build. The resulting artifacts are written back
into the remote cache. The remote cache is shared between remote dev workstations,
the GH Action runners, and the BB CI workflow. 

## Inner Dev Loop

It is generally recommended to build and test only the source tree one is working on.
For example, working on the Golang source tree leads to:

```Bash
bazel build -c opt --config=ci //go/...

bazel test -c opt --config=ci //go/...
```


For even more specific targets, use the file path. For example:

```Bash
bazel build -c opt --config=ci //elixir/serviceradar_srql/...
```

Note that the trailing three dots simply mean "anything" below this path. Also note that Bazel 
picks up all changes in dependencies automatically and compiles the difference to the 
previous build.

Building sub-targets may cause upstream targets to rebuild in case of a
full repo rebuild. However, it is common to skip the full rebuild until 
the local work has been completed.

When ready to open a PR, run the following to complete some pre-PR checks:

```Bash
make check
```

This script:
* Builds the entire repo
* Runs all unit tests
* Runs the Golang race condition tests

Synchronize and rebase the feature branch against `origin/staging` separately before this gate;
`make check` never mutates Git history.

Depending on the scope of local changes, this may take a few minutes. The configuration used
by the check script is identical to the BB CI config, and it runs on the same BB cluster as the BB CI workflow. 

The build progress can be tracked in the BB dashboard:

https://carverauto.buildbuddy.io

When ready, open a PR from a feature branch and follow the CI checks.


## Outer Dev Loop

CI is split between Forgejo Actions and the self-hosted BuildBuddy workflow. Both use the shared
cache proxy; database-facing TestRunner actions stay on fixture-reachable workflow runners while
eligible compile actions remain remote and cached.
