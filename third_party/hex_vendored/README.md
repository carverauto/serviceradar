# Vendored Hex packages

Upstream Hex packages checked in as **unpacked source** and compiled from here,
rather than fetched. Each is a Mix path dependency *and* a Bazel `mix_app`, and
both build systems read this one tree.

Not to be confused with `//third_party/hex`, which holds generated `*.BUILD`
files for packages that *are* fetched. Those become `@hex_<name>` external
repos, reached through the `@hexpm//:<name>` hub.

| Package | Why it is vendored |
| --- | --- |
| `boombox` | Patched: the generic HTTP media-file source (`membrane_hackney_plugin`) is removed, because hackney pulls h2, which collides with grpcbox's chatterbox during `mix release`. `@hex_boombox` is deliberately unbuildable. |
| `connection` | Shadows the Hex package; overrides the registry resolution for the `gnat -> connection` edge. |
| `elixir_uuid` | Shadows the Hex package. |
| `opentelemetry_oban` | Local fork. |

## Adding or moving one

Three places must agree, or the failure is a confusing "module X is not loaded"
rather than a missing dependency:

1. The Mix path dep in each consuming `mix.exs`, relative to that project
   (`elixir/<app>/` → `../../third_party/hex_vendored/<pkg>`).
2. The Bazel labels in each consuming `BUILD.bazel` — both `:erlang_app` and the
   `:mix.exs` entry that `elixir_release` needs to read the app name and version.
3. `third_party/hex/gen_hex_bazel.exs`'s `@path_deps` map, which rewrites the
   dependency edge inside generated `//third_party/hex/*.BUILD` files. **Those
   generated files have the label baked in** — regenerate with
   `bazel run //third_party/hex:gen`. Missing this leaves a stale label that
   only fails at build time, in an external repo.

Labels there must be `@serviceradar//`-qualified: the generated BUILD files are
evaluated inside the `@hex_<pkg>` repositories, where a bare `//third_party/...`
would resolve against the Hex package instead of this repo.
