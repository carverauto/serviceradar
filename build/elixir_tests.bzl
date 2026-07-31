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
        load_config = True,
        pre_load = [],
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
      load_config: evaluate the project's config/config.exs into the application
        environment before test_helper runs, the way `mix test` does. Set False for a
        project that has no config/ or must not have it applied.
      pre_load: .exs files loaded BEFORE the config loader. For anything that has to shape
        the environment config/*.exs then reads -- deriving a database URL, for instance.
      size: Bazel test size. A group can hold hundreds of files, so "large".
      tags: Bazel tags applied to every generated target.
      **kwargs: forwarded to each ex_unit_test.
    """

    # test_helper is almost always inside the same tree a caller globs for data
    # (test/**), and Bazel rejects a duplicated label in an attribute.
    extra_data = [d for d in data if d != test_helper]

    # `elixir -r` does not evaluate config/config.exs the way `mix test` does, so a loader
    # runs first. It is staged at its own workspace-relative path while the test runs from
    # the package directory, hence the climb back up.
    # Ahead of the config loader, so these can set what config/*.exs goes on to read.
    pre_load_opts = []
    for path in pre_load:
        pre_load_opts = pre_load_opts + ["-r", path]
        if path not in extra_data:
            extra_data = extra_data + [path]

    config_loader_opts = []
    if load_config:
        depth = len(native.package_name().split("/")) if native.package_name() else 0
        loader = ("../" * depth) + "build/elixir_test_config_loader.exs"
        config_loader_opts = ["-r", loader]

        # The project's own config/ tree, not just the loader script.
        #
        # The loader reads config/config.exs relative to the package directory, and treats a
        # missing one as "this project has no config", which is legitimate. That guard turns
        # a staging mistake into silence: without these files the loader applies NO
        # configuration and the tests run against every library's .app defaults.
        #
        # It cost a full debugging cycle. serviceradar_core's integration tier boots the
        # application; with config/ unstaged, `config :swoosh, :api_client, false` never
        # landed, Swoosh fell back to its default Swoosh.ApiClient.Hackney, and the VM died
        # with "Could not find hackney dependency" -- a dependency the project does not have
        # and whose absence is correct. Nothing in that error points at staging.
        #
        # Adding it here rather than at each call site is what makes load_config = True mean
        # what it says: no caller can enable it and forget the data.
        extra_data = extra_data + ["//build:elixir_test_config_loader.exs"] + native.glob(
            ["config/**"],
            allow_empty = True,
        )

    groups = {}
    for src in srcs:
        groups.setdefault(_group_key(src, strip_prefix, group_depth), []).append(src)

    groups = _subdivide(groups, strip_prefix, group_depth, max_group_size, min_subgroup_size)

    tests = []
    for group in sorted(groups):
        # Namespaced under the suite name: a group is named after a test subdirectory, and
        # those collide with other targets in the package. serviceradar_agent_gateway has
        # test/serviceradar_agent_gateway/, whose bare group name collides with mix_app's
        # own <app_name>/ output directory ("one of the output paths ... is a prefix of the
        # other").
        target = "{}_{}".format(name, group)
        ex_unit_test(
            name = target,
            size = size,
            # test_helper must load BEFORE the test files: `use ExUnit.Case` raises at
            # module compile time if ExUnit is not started. It cannot go in srcs --
            # buildifier sorts srcs alphabetically and the rule preserves that order, so
            # a helper named test_helper.exs would load after a test named e.g.
            # accounts_test.exs. elixir_opts are emitted ahead of srcs, so the -r goes
            # there and the helper travels as data.
            srcs = sorted(groups[group]),
            data = [test_helper] + extra_data,
            elixir_opts = pre_load_opts + config_loader_opts + ["-r", test_helper],
            tags = tags,
            deps = deps,
            **kwargs
        )
        tests.append(":" + target)

    native.test_suite(
        name = name,
        tests = tests,
        tags = tags,
    )
