"""Run the Hex BUILD-stub generator, as a Bazel target rather than a loose script.

Two rules over one implementation, because the generator is used two ways:

  hex_gen       `bazel run` -- rewrites the checked-in tree from the live mix.lock files.
  hex_gen_test  `bazel test` -- regenerates into TEST_TMPDIR from declared inputs and
                diffs against the checked-in tree, so a lock change that nobody
                regenerated fails CI instead of silently shipping a stale closure.

The generator needs Elixir. Taking it from the hermetic rules_elixir toolchain rather
than $PATH is what lets the test run on RBE and keeps the output independent of whatever
Elixir a developer happens to have installed.
"""

load(
    "@rules_elixir//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "erlang_preamble",
)

# Regenerating writes into this package. Derived from the rule's own label so the two
# never drift: the generated stubs sit next to the generator that emits them.
def _package_dir(ctx):
    return ctx.label.package

def _elixir_preamble(ctx):
    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx, short_path = True)

    preamble = """\
{erlang_preamble}
if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"$ABS_ERLANG_HOME"/bin:${{PATH}}
""".format(
        erlang_preamble = erlang_preamble(ctx, short_path = True),
        erlang_home = erlang_home,
        elixir_home = elixir_home,
    )

    return (preamble, [erlang_runfiles, elixir_runfiles])

def _impl(ctx):
    (preamble, toolchain_runfiles) = _elixir_preamble(ctx)

    # short_path of a source file is its workspace-relative path, which is also where it
    # sits in the runfiles tree. One string works for both modes: prefixed with
    # $BUILD_WORKSPACE_DIRECTORY when writing the real tree, used as-is under runfiles.
    locks = " ".join([f.short_path for f in ctx.files.locks])
    generator = ctx.file.generator.short_path
    package = _package_dir(ctx)

    if ctx.attr.is_test:
        body = """\
out="$TEST_TMPDIR/generated"
mkdir -p "$out"
export HOME="$TEST_TMPDIR"

"$ABS_ELIXIR_HOME"/bin/elixir "$PWD/{generator}" --out-dir "$out" {locks}

status=0
for generated in "$out"/*; do
    name="$(basename "$generated")"
    if ! diff -u "{package}/$name" "$generated"; then
        status=1
    fi
done

# A stub the locks no longer produce is just as stale as one that changed. The generator
# prunes these when it rewrites the tree, so their presence means it was never re-run.
for checked_in in {package}/*.BUILD; do
    name="$(basename "$checked_in")"
    if [ ! -e "$out/$name" ] && grep -q "{marker}" "$checked_in"; then
        echo "stale: {package}/$name is generated but no longer in any mix.lock"
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    echo ""
    echo "//{package} is out of date with the mix.lock files."
    echo "Regenerate it with: bazel run //{package}:gen"
fi
exit "$status"
""".format(
            generator = generator,
            locks = locks,
            package = package,
            marker = ctx.attr.generated_marker,
        )
    else:
        body = """\
if [ -z "${{BUILD_WORKSPACE_DIRECTORY:-}}" ]; then
    echo "this target must be invoked with 'bazel run', not 'bazel build'" >&2
    exit 1
fi

generator="$PWD/{generator}"
cd "$BUILD_WORKSPACE_DIRECTORY"
"$ABS_ELIXIR_HOME"/bin/elixir "$generator" --out-dir "{package}" {locks}
""".format(
            generator = generator,
            locks = locks,
            package = package,
        )

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = script,
        content = "#!/usr/bin/env bash\nset -euo pipefail\n\n" + preamble + "\n" + body,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = ctx.files.locks + [ctx.file.generator] + ctx.files.data)
    for extra in toolchain_runfiles:
        runfiles = runfiles.merge(extra)

    return [DefaultInfo(executable = script, runfiles = runfiles)]

_ATTRS = {
    "generator": attr.label(
        allow_single_file = True,
        mandatory = True,
        doc = "The .exs generator to run.",
    ),
    "locks": attr.label_list(
        allow_files = True,
        mandatory = True,
        doc = "Every project's mix.lock. All of them, so the closure is resolved once.",
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = "Checked-in generated files, needed as declared inputs by the test.",
    ),
    "generated_marker": attr.string(
        default = "do not edit by hand",
        doc = "Substring identifying a generated stub, so hand-written ones survive pruning.",
    ),
    "is_test": attr.bool(default = False),
}

hex_gen = rule(
    implementation = _impl,
    attrs = _ATTRS,
    executable = True,
    toolchains = ["@rules_elixir//:toolchain_type"],
)

hex_gen_test = rule(
    implementation = _impl,
    attrs = _ATTRS | {"is_test": attr.bool(default = True)},
    test = True,
    toolchains = ["@rules_elixir//:toolchain_type"],
)
