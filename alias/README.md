# Bazel aliases

This project uses Bazel aliases extensively for dependencies management for a number of reasons:

* Aliases ensure that if a package relocates to a different folder,
  only its alias in [alias/BUILD.bazel](alias/BUILD.bazel) needs to be update to let the build resume.
* Aliases keep bazel dependencies in a flat namespace that is easy to navigate.
* Alias simplify migrations in case of a library rewrite as the new library can be written and tested in parallel to the
  old one and only when its its ready the alias can be updated to the new library.

In practice, you write your library with its Build file as usual, and then you add an alias to [alias/BUILD.bazel](alias/BUILD.bazel); for example:

```text 
alias(
    name = "dusk",
    actual = "//pkg/checker/dusk:dusk",
)
```

Note, Bazels target  names are path dependent and must be unique within the path.
For example, when you have a binary agent and a library agent, the library agent must be named `lib_agent` and the binary agent must be named `agent` when both are aliased within the alias/BUILD.bazel file.

In practice, it is often sensible to segment the alias namespace wit a few folders, for example:

```
alias/
    service/
    client/
    test_tools/
``` 

Which then translates to dependency paths like:

```text 
    deps = [
        "//alias/service:agent",
        "//alias:models",
        ...
    ],
```

That way, you can have a client and service having the same name because they reside in two different namespaces. The convention " "//alias/service:agent"," makes it clear that here, agent is a service and an alias. 

Aliases work the same way as regular Bazel targets so they can be queried, build, and tested just as the aliased target would. 

By convention, test targets are never aliased because tests are usually tagged so that Bazel can query all tests for a given tag and run them all. 

