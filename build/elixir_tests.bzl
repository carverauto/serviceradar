"""Generate ex_unit_test targets from a tree of ExUnit files, grouped by directory.

Granularity is a trade-off, and one target per test FILE is the wrong end of it.
rules_erlang stages the whole ERL_LIBS tree -- ~140 applications for
serviceradar_core -- separately for every ex_unit_test target. At one target per
file that is 595 x 140 staging actions before a single test runs, which in
practice never finished on a developer machine.

Grouping by top-level test directory keeps what actually mattered:

  * cacheability -- a group whose files did not change is a cache hit;
  * identifiable failures -- with --test_output=errors only the failing group
    prints, and ExUnit names the file and line inside it. The job this replaces
    emitted a single 44MB log in which four failures were near line 239,878;
  * some parallelism, across groups and across the projects wired into the same
    Bazel invocation;

while keeping per-target ERL_LIBS staging proportional to the number of groups
rather than the number of test files.

Group names come from the directory layout, so they stay meaningful and a new
test file needs no generator run and nothing kept in sync. Which tests actually
execute is decided at runtime by the project's own test_helper.exs, which
excludes [:integration, :external, :cluster, :large_ingestion, :benchmark]
unless a database URL is present in the environment. That keeps the "what needs
a database" decision in the place that already owned it, rather than
duplicating it into a Bazel-side list that would go stale.
"""

load("@rules_elixir//:ex_unit_test.bzl", "ex_unit_test")

def _group_key(src, strip_prefix, group_depth):
    """Directory prefix of src, group_depth components deep, as a target name."""
    rel = src
    if strip_prefix and rel.startswith(strip_prefix):
        rel = rel[len(strip_prefix):]

    parts = rel.split("/")

    # A file shallower than group_depth is its own group, named after the file, so
    # it can never collide with a directory group.
    if len(parts) <= group_depth:
        stem = parts[-1]
        if stem.endswith(".exs"):
            stem = stem[:-len(".exs")]
        return "_".join(parts[:-1] + [stem])

    return "_".join(parts[:group_depth])

def _subdivide(groups, strip_prefix, group_depth, max_group_size, min_subgroup_size):
    """Split any group over max_group_size into its next-level children.

    A child smaller than min_subgroup_size is not worth its own target -- each
    one costs a full ERL_LIBS staging and a BEAM start -- so the small children
    are pooled into a single `<parent>_other`.
    """
    out = {}
    for group, group_srcs in groups.items():
        if len(group_srcs) <= max_group_size:
            out[group] = group_srcs
            continue

        children = {}
        for src in group_srcs:
            children.setdefault(_group_key(src, strip_prefix, group_depth + 1), []).append(src)

        pooled = []
        for child in sorted(children):
            if len(children[child]) >= min_subgroup_size:
                out[child] = children[child]
            else:
                pooled.extend(children[child])

        if pooled:
            out[group + "_other"] = pooled

    return out

def ex_unit_tests(
        name,
        test_helper,
        deps,
        srcs,
        data = [],
        strip_prefix = "test/",
        group_depth = 1,
        max_group_size = 100,
        min_subgroup_size = 20,
        size = "large",
        tags = [],
        **kwargs):
    """Declare one ex_unit_test per directory group, plus a test_suite over them.

    Args:
      name: name of the test_suite gathering every generated target.
      test_helper: the ExUnit helper (e.g. "test/test_helper.exs"). See below.
      deps: ErlangAppInfo deps, normally the app under test.
      srcs: the test files, normally a glob of test/**/*_test.exs.
      data: extra runtime files every group needs.
      strip_prefix: trimmed from each src before deriving the group.
      group_depth: how many leading path components form a group.
      max_group_size: a group with more files than this is split one level deeper,
        so that a failure in one subsystem does not invalidate the cached result
        of every other subsystem sharing its top-level directory.
      min_subgroup_size: when splitting, children smaller than this are pooled
        into `<parent>_other` rather than each paying a full ERL_LIBS staging.
      size: Bazel test size. A group can hold hundreds of files, so "large".
      tags: Bazel tags applied to every generated target.
      **kwargs: forwarded to each ex_unit_test.
    """

    # test_helper is almost always inside the same tree a caller globs for data
    # (test/**), and Bazel rejects a duplicated label in an attribute.
    extra_data = [d for d in data if d != test_helper]

    groups = {}
    for src in srcs:
        groups.setdefault(_group_key(src, strip_prefix, group_depth), []).append(src)

    groups = _subdivide(groups, strip_prefix, group_depth, max_group_size, min_subgroup_size)

    tests = []
    for group in sorted(groups):
        ex_unit_test(
            name = group,
            size = size,
            # test_helper must load BEFORE the test files: `use ExUnit.Case` raises at
            # module compile time if ExUnit is not started. It cannot go in srcs --
            # buildifier sorts srcs alphabetically and the rule preserves that order, so
            # a helper named test_helper.exs would load after a test named e.g.
            # accounts_test.exs. elixir_opts are emitted ahead of srcs, so the -r goes
            # there and the helper travels as data.
            srcs = sorted(groups[group]),
            data = [test_helper] + extra_data,
            elixir_opts = ["-r", test_helper],
            tags = tags,
            deps = deps,
            **kwargs
        )
        tests.append(":" + group)

    native.test_suite(
        name = name,
        tests = tests,
        tags = tags,
    )
