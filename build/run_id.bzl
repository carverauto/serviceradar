"""The per-run disposable database name, as a declared build input.

The integration lifecycle is six separate Bazel invocations -- sweep, prepare template,
migrate, provision, test, teardown. They share no process and cannot hand values to each
other, so every step must independently arrive at the SAME database name, and two runs that
can overlap must arrive at DIFFERENT ones. That is a run correlation id, and it can only come
from outside the build.

It arrives as `--//build:run_id=<id>`, which the caller fixes once and repeats on all six
invocations. The command line is the build's declared input, so no step reads ambient process
environment to find out which database it is talking to.

Cache impact is confined by construction. This rule is a LEAF -- it has no dependencies -- so
whatever configuration fingerprint reading the build setting gives it, there is nothing
underneath to propagate to. Consumers take its output file as `data`, which changes an
action's inputs but not its configuration, so every `rustc` and Mix compile in the graph keeps
its cache key when the run id changes.

The file holds the full base name rather than the bare id, so the format has ONE producer.
Rust and Elixir previously derived it separately and carried a comment warning that the two
"must agree exactly or the suite runs against a database nothing provisioned".
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _run_id_file_impl(ctx):
    run_id = ctx.attr.run_id[BuildSettingInfo].value

    # An unset flag writes an EMPTY file rather than failing here. Failing at analysis would
    # break any wildcard build that reaches this target, and it cannot explain the six-step
    # lifecycle the way the consuming code can. The readers fail closed instead -- there is no
    # fallback name, because a constant fallback is what let two concurrent runs share one
    # database and tear down each other's data.
    content = ctx.attr.prefix + run_id if run_id else ""

    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(output = out, content = content)

    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]),
    )]

run_id_file = rule(
    implementation = _run_id_file_impl,
    doc = "Writes the per-run base database name, or an empty file when --//build:run_id is unset.",
    attrs = {
        "prefix": attr.string(
            default = "sr_core_test_",
            doc = "Disposable-database prefix. Consumers guard on this independently, so a " +
                  "mismatch fails loudly rather than targeting an unrelated database.",
        ),
        "run_id": attr.label(
            mandatory = True,
            providers = [BuildSettingInfo],
            doc = "The //build:run_id string_flag.",
        ),
    },
)
