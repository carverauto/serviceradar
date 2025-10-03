"""Helper rules for deriving immutable OCI image tags."""

def _immutable_tag_file_impl(ctx):
    if ctx.attr.short_length <= 0:
        fail("short_length must be positive")

    digest_file = ctx.file.digest
    commit_file = ctx.file.commit_tags
    out = ctx.outputs.tags

    args = [
        digest_file.path,
        ctx.attr.digest_prefix,
        str(ctx.attr.short_length),
        out.path,
        commit_file.path if commit_file else "",
    ] + ctx.attr.static_tags

    command = """
set -euo pipefail

digest=$(cat "$1")
if [[ "$digest" != sha256:* ]]; then
  echo "unexpected digest format: $digest" >&2
  exit 1
fi

prefix="$2"
length="$3"
out="$4"
commit_file="$5"
shift 5

short=$(printf '%s' "${digest#sha256:}" | cut -c1-"${length}")

{
  if [[ -n "$commit_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ -n "$line" ]]; then
        printf '%s\\n' "$line"
      fi
    done < "$commit_file"
  fi

  for tag in "$@"; do
    if [[ -n "$tag" ]]; then
      printf '%s\\n' "$tag"
    fi
  done

  printf '%s%s\\n' "$prefix" "$short"
} > "$out"
"""

    inputs = [digest_file]
    if commit_file:
        inputs.append(commit_file)

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        command = command,
        arguments = args,
        progress_message = "Deriving immutable tags for {}".format(ctx.label.name),
        mnemonic = "GenerateImmutableTags",
    )

immutable_push_tags = rule(
    implementation = _immutable_tag_file_impl,
    doc = "Writes an immutable tag list combining static tags with a short digest hash.",
    attrs = {
        "digest": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "commit_tags": attr.label(
            allow_single_file = True,
            doc = "Optional file providing commit-derived tags (one per line).",
        ),
        "static_tags": attr.string_list(
            default = [],
            doc = "Additional fixed tags to include (e.g. latest).",
        ),
        "digest_prefix": attr.string(
            default = "sha-",
            doc = "Prefix applied to the digest-based tag.",
        ),
        "short_length": attr.int(
            default = 12,
            doc = "Number of digest characters to include in the generated tag.",
        ),
    },
    outputs = {"tags": "%{name}.txt"},
)
