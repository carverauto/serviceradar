"""Whether this checkout may WRITE the shared template database, `sr_core_template`.

That template is cloned by every run and only ever ratchets forward: migrations are
append-only and are never rolled back, so whatever is applied to it accumulates and becomes
the schema every later run gets. For that cache to be correct for everyone, its contents have
to be a subset of what EVERY branch has, and the only practical set with that property is
trunk's, because every branch is based on trunk.

Until //buildbuddy.yaml was restructured, it was written by whichever run reached the migrator
first -- and BazelCI triggers on `pull_request` only, so in practice that was always a branch
whose migrations were unmerged. One such branch left seven migrations behind and every other
pull request was then refused a clone, including ones whose diff contained no migration at
all, because the ahead-check correctly told them to rebase onto a branch that could not be
merged. Note the branch does NOT have to be red for this: a GREEN unmerged branch poisons the
template exactly the same way. The property that matters is whether the migrations are on
trunk, not whether the run passed.

Restructuring the workflow moved every branch onto a per-run base and left the shared template
named only by the push-to-`staging` action. That is the fix; this flag is what makes it hold.
Placement in a YAML file is a convention a later edit can undo silently and a workstation
never obeyed at all -- the lifecycle is documented as runnable by hand against the same shared
CNPG fixture CI uses, so a work-in-progress migration on a developer's machine could ratchet
the fixture for everyone, from a machine no reviewer would think to look at.

What is gated is the RATCHET -- the migration set the template carries. Creating it when it is
absent is not gated and stays in `ensure_template`, which any run's `provision_base` may reach:
an empty template is a cache MISS for everyone, since every reader clones it and then migrates
its own run base. Applying a migration is the decision that outlives the run, and that is what
only trunk may make.

So the write targets now require the caller to say so:

    bazel ... --//build:template_authority=true //rust/integration-db:prepare_template

It means "this checkout is trunk, and the shared template may be brought to match it". Only
the push-to-`staging` action in //buildbuddy.yaml passes it. Everything else -- every pull
request, every benchmark branch, and every developer running the lifecycle by hand -- leaves
it false, and the write targets refuse rather than quietly doing something else, because a
caller that reached for the template meant the template.

Delivered as a FILE for the same reason //build:run_id_file is. The lifecycle is several
separate Bazel invocations sharing no process, and both Rust (`prepare_template`,
`reset_template`) and Elixir (`migrate_template`) must reach the same answer. Reading it from
ambient process environment would let one step's answer differ from another's; a declared
input cannot, and it is visible in the action graph rather than in a shell's exported state.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

# The file's entire contract. Any other content -- including the empty file an unset flag
# writes -- means "not the authority", so a misspelling fails CLOSED: the write is refused,
# which is the safe side, because a refusal leaves the template exactly as it was found.
_AUTHORITY_MARKER = "trunk"

def _template_authority_file_impl(ctx):
    authority = ctx.attr.template_authority[BuildSettingInfo].value

    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(output = out, content = _AUTHORITY_MARKER if authority else "")

    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]),
    )]

template_authority_file = rule(
    implementation = _template_authority_file_impl,
    doc = "Writes the trunk marker when --//build:template_authority is set, else an empty file.",
    attrs = {
        "template_authority": attr.label(
            mandatory = True,
            providers = [BuildSettingInfo],
            doc = "The //build:template_authority bool_flag.",
        ),
    },
)
