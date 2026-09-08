"""Opt-in guard for targets that touch the shared CNPG fixture."""

def requires_shared_fixture():
    """`target_compatible_with` value gating a target behind an explicit flag.

    Use on any target that runs DDL against the shared CNPG fixture -- a database that
    concurrent pull requests share, where an accidental run is destructive rather than
    merely slow.

    Without `--//build:enable_integration_tests` the target is INCOMPATIBLE:

      * a wildcard (`bazel test //...`) skips it and reports it as skipped, so the guard
        is visible in the output rather than inferred from a test count;
      * naming it explicitly is a hard error that names the target and the constraint.

    That is the whole reason this replaced `manual`. `manual` also kept a target out of
    wildcards, but silently, and it said nothing when an explicit invocation was filtered
    away -- the failure read as "no such target" (exit 4). It also conflated "needs a
    database" with "never expand me", so one tag was doing two unrelated jobs.

    Tag selection and this guard are orthogonal and both are wanted: `integration_test`
    chooses WHICH tests an invocation addresses, this decides WHETHER they may run at all.
    """
    return select({
        "//build:integration_tests_enabled": [],
        "//conditions:default": ["@platforms//:incompatible"],
    })
