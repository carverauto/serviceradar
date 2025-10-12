# Bazel


In addition to Cargo and related tools, the entire mono-repo is configured to build and test with Bazel. 
Please [install bazelisk ](https://github.com/bazelbuild/bazelisk)as it is the only requirement to build the repo with Bazel.

To query available crate aliases with Bazel, run:

```bash 
    bazel query "kind('alias', //alias/...)"
```

Note, this project uses Bazel aliases extensively for dependencies to ensure that if a package relocates to a different folder, 
only its alias in [alias/BUILD.bazel](alias/BUILD.bazel) needs to be update to let the build resume.

To build all targets with Bazel, run:

```bash 
    bazel build //...
```

To build only a specific target and its dependencies, run:

```bash 
    bazel build //cmd/... 
```

To test all targets with Bazel, run:

```bash 
    bazel test //...
```

To test only a specific target, run:

```bash 
    bazel test //cmd/...
```

To query all available tests to find, for example, all agent tests, run:

```bash 
    bazel query "kind('go_test', //...)" | grep agent_test 
```

To run the located test targets, run:


```bash 
    bazel test //pkg/agent:agent_test
```

To explore all dependencies of a specific crate, run:

```bash 
    bazel query "deps(//alias:agent)"
```

To find all reverse dependencies, i.e. packages that depends on a specific crate, run:

```bash 
    bazel query "rdeps(//..., //alias:agent, 1)"
```

If you were to refactor the dcl_data_structures crate, the rdepds tell you
upfront were its used and thus helps you to estimate upfront the blast radius of braking changes.

To query available vendored external dependencies with Bazel, run:

```bash 
    bazel query "kind('go_library', //third_party/...)"
```

Note, these vendored external dependencies are shared across all crates.

To visualize all dependencies of the top level binary agent, run

```bash 
   bazel query 'deps(//cmd/agent, 3) ' --output graph --noimplicit_deps  | dot -Tpng -o graph.png
   
   open graph.png # Works on Mac. 
```

## References:

https://bazel.build/query/guide

https://buildkite.com/resources/blog/a-guide-to-bazel-query/