# OCaml Migration with Bazel

## Current Layout
- `ocaml/dune-project` (lang dune 3.20); primary code lives under `ocaml/srql`.
- Library: `ocaml/srql/lib/dune` defines `srql_translator` library depending on `yojson`, `proton`, `lwt`, `ppx_deriving.show`, `lwt_ppx`.
- Executables: `ocaml/srql/bin/dune` defines `srql-server`, `srql-translator`, `srql-cli` (all depend on `srql_translator`).
- Tests: `ocaml/srql/test/dune` uses `alcotest` + `srql_translator` (plus `run_live_srql` binary).
- Package metadata: `ocaml/srql-translator.opam` targets OCaml `>=5.1`, dune `>=3.20`, plus above deps.

## Selected Ruleset
- `rules_ocaml` 3.0.0.beta.1 (pinned via `archive_override`).
- `rules_ocaml` does **not** ship a Bazel Central Registry module yet; it assumes:
  - OCaml toolchains defined via `ocaml/opam` repositories.
  - Integration with [`tools_opam`](https://github.com/obazl/tools_opam) to translate opam switch metadata into Bazel repos.

## Proposed Bazel wiring
1. **Tooling dependencies**
   ```starlark
   archive_override(
       module_name = "tools_opam",
       urls = ["https://github.com/obazl/tools_opam/archive/refs/tags/1.0.0.beta.1.tar.gz"],
       strip_prefix = "tools_opam-1.0.0.beta.1",
       integrity = "sha256-ElwMXfSAGsavBQO9iMAno6NiaDQ31PJmitVe/vJiTJM=",
   )
   bazel_dep(name = "tools_opam", version = "1.0.0.beta.1")

   # Additional companion modules (all pinned via archive_override):
   archive_override(module_name = "obazl_tools_cc", integrity = "sha256-vh4YXopUJiBe5pvBt6+MQAN2WIz+QrmRGg+v6r1GdZs=", strip_prefix = "obazl_tools_cc-3.0.0", urls = ["https://github.com/obazl/obazl_tools_cc/archive/refs/tags/3.0.0.tar.gz"])
   archive_override(module_name = "findlibc", integrity = "sha256-Btxdss/Y16n05z84xUlLbJeKzM/oWeTY3+zvf6qN820=", strip_prefix = "findlibc-3.0.0", urls = ["https://github.com/obazl/findlibc/archive/refs/tags/3.0.0.tar.gz"])
   archive_override(module_name = "runfiles", integrity = "sha256-qjvMYGxauHRWuY6gOwIdZFj8eJfzv24lpeyX4Dv7/FI=", strip_prefix = "runfiles-3.0.0", urls = ["https://github.com/obazl/runfiles/archive/refs/tags/3.0.0.tar.gz"])
   archive_override(module_name = "xdgc", integrity = "sha256-OHNCvHJe7+JenXQSqcKuSlzlL8Q+0gC17RP5FDx2kXM=", strip_prefix = "xdgc-3.0.0", urls = ["https://github.com/obazl/xdgc/archive/refs/tags/3.0.0.tar.gz"])
   archive_override(module_name = "gopt", integrity = "sha256-cyd1bgKXCkskTpIN2eWdmMBGD2diXY+ZzmxXpGEOBlY=", strip_prefix = "gopt-10.0.0", urls = ["https://github.com/obazl/gopt/archive/refs/tags/10.0.0.tar.gz"])
   archive_override(module_name = "liblogc", integrity = "sha256-C/7itdldocCde/Hm21PGQRJHHttvevUl/yrdAMCbYVE=", strip_prefix = "liblogc-3.0.0", urls = ["https://github.com/obazl/liblogc/archive/refs/tags/3.0.0.tar.gz"])
   archive_override(module_name = "makeheaders", integrity = "sha256-TWphcN+KX42HLb3+SLFSu39U+8ZcooWWminzMAVvmbQ=", strip_prefix = "makeheaders-3.0.0", urls = ["https://github.com/obazl/makeheaders/archive/refs/tags/3.0.0.tar.gz"])
   archive_override(module_name = "semverc", integrity = "sha256-d9t+oZ2y7oC3P1BwcK7cKSn1YCY2wapbRZbxaKprpzA=", strip_prefix = "semverc-3.0.0", urls = ["https://github.com/obazl/semverc/archive/refs/tags/3.0.0.tar.gz"])
   archive_override(module_name = "sfsexp", integrity = "sha256-EA5IfSiJ9+ocrMI8pZMLpuHBMfugk5lLF7t/C4HFQfE=", strip_prefix = "sfsexp-1.4.1.bzl", urls = ["https://github.com/obazl/sfsexp/archive/refs/tags/1.4.1.bzl.tar.gz"])
   archive_override(module_name = "uthash", integrity = "sha256-FGY0b/dX4DFmloaKY+yHq2CLa9RJy/6eR+VdpLq884Y=", strip_prefix = "uthash-2.3.0.bzl", urls = ["https://github.com/obazl/uthash/archive/refs/tags/2.3.0.bzl.tar.gz"])
   # `unity` is a dev_dependency of tools_opam; add an override if we enable its test targets.
   ```
   `cwalk` 1.2.9 is vendored under `third_party/cwalk` (commit e98d23f) with a `local_path_override` until upstream publishes an official release tag.

2. **Opam->Bazel module extension**
   ```starlark
   opam = use_extension("@tools_opam//extensions:opam.bzl", "opam")
   opam.deps(
       ocaml_version = "5.1.0",
       pkgs = {
           "dune": "3.20.2",
           "menhir": "20250903",
           "yojson": "2.2.2",
           "ppx_deriving": "6.0.3",
           "lwt_ppx": "5.9.1",
           "proton": "1.0.15",
           "lwt": "5.9.2",
           "dream": "1.0.0~alpha7",
       },
   )
   opam_dev = use_extension("@tools_opam//extensions:opam.bzl", "opam", dev_dependency = True)
   opam_dev.deps(pkgs = {"alcotest": "1.9.0"})

   use_repo(opam, "opam.ocamlsdk", "opam.dune", "opam.menhir", "opam.yojson", "opam.ppx_deriving", "opam.lwt_ppx", "opam.proton", "opam.lwt", "opam.dream")
   use_repo(opam_dev, "opam.alcotest")

   register_toolchains("@opam.ocamlsdk//toolchain/selectors/local:all")
   register_toolchains("@opam.ocamlsdk//toolchain/profiles:all")
   ```
   - Captures the opam packages required by `srql-translator.opam` and exports them as Bazel repos.
   - Requires `opam` to be available in PATH so module resolution can install and configure the packages.

3. **OCaml toolchain registration**
   - The `opam.ocamlsdk` repository exposes host-aware toolchains once we call `register_toolchains("@opam.ocamlsdk//toolchain/...")` in `MODULE.bazel`.
   - Confirm macOS arm64 + Linux x86_64 coverage; adjust selector/profile registration if we need additional targets beyond what `tools_opam` emits by default.

4. **BUILD files**
   - Create `ocaml/BUILD.bazel` that loads rule macros:
     ```starlark
     load("@rules_ocaml//build:rules.bzl", "ocaml_library", "ocaml_binary", "ocaml_test", "ocamllex", "ocamlyacc")

     ocaml_library(
         name = "srql_translator",
         srcs = glob(["srql/lib/**/*.ml", "srql/lib/**/*.mli"]),
         deps = [
             "@opam.yojson//:yojson",
             "@opam.proton//:proton",
             "@opam.lwt//:lwt",
             "@opam.ppx_deriving//:ppx_deriving.show",
             "@opam.lwt//:lwt_ppx",
         ],
         preprocess = ["ppx_deriving.show", "lwt_ppx"],
     )
     ```
   - Executables:
     ```starlark
     ocaml_binary(
         name = "srql_server",
         srcs = ["srql/bin/main.ml"],
         deps = [":srql_translator", "@opam.dream//:dream", "@opam.yojson//:yojson"],
     )
     ocaml_binary(
         name = "srql_translator_cli",
         srcs = ["srql/bin/cli.ml"],
         deps = [":srql_translator", "@opam.yojson//:yojson"],
     )
     ocaml_binary(
         name = "srql_cli",
         srcs = ["srql/bin/srql_cli.ml"],
         deps = [":srql_translator", "@opam.lwt//:lwt", "@opam.lwt//:lwt.unix"],
     )
     ```
   - Tests (wrap with `ocaml_test` once ocaml rules semantics confirmed):
     ```starlark
     ocaml_test(
         name = "test_json_conv",
         srcs = ["srql/test/test_json_conv.ml"],
         deps = [":srql_translator", "@opam.alcotest//:alcotest", "@opam.yojson//:yojson"],
     )
     ```
   - Provide aggregated test target (e.g. `test_suite` in Bazel or `ocaml_test` multi-target).

5. **Menhir/lex/yacc support**
   - `srql` currently has menhir disabled. If re-enabled, integrate [`rules_menhir`](https://github.com/ocaml-sf/menhir) (`bazel_dep` + `menhir_parser` macros) and the `ocamllex`/`ocamlyacc` macros from `rules_ocaml`.

6. **CI parity**
   - Add `bazel test //ocaml/...` smoke job once toolchains compile.
   - Map existing dune `run_live_srql` integration to `bazel run` (mark as manual).

## Outstanding Questions
- `tools_opam` generated repos for core deps (`yojson`, `proton`, `lwt`, etc.) load, but `ppx_deriving` still collides with its generated `ocaml_import`; attempted string suffix patching in `emit_build_bazel.c`, but Bazel still emits the conflicting target. Need a more targeted override before wiring SRQL BUILD files.
- Confirm whether `tools_opam`/`rules_ocaml` support OCaml 5.1 across macOS arm64 + Linux x86_64 without custom patches.
- Determine packaging for proprietary dependencies (`proton` OPAM package availability). If not published, consider vendoring via `opam_local_package` or `http_archive`.
- Decide on caching strategy for opam downloads in CI (tools_opam opts to download at module resolution).

## Next Actions
1. Inspect the generated `@opam.*` repositories to confirm target names (`bazel query @opam.yojson//...`).
2. Prototype Bazel BUILD rules for `srql_translator` and binaries; validate `bazel build //ocaml:srql_translator` once wired.
   - `//ocaml/srql/BUILD.bazel` now defines the core library, binaries, and Alcotest wrappers. The vendored `tools_opam` fork rewrites the generated `digestif` repositories (root alias → OCaml subpackage, cleaned subpackage deps), so `bazel build //ocaml/srql:srql_translator` succeeds locally.
   - `Proton_client` now inlines parameter values when executing queries because the upstream Proton client lacks prepared-statement APIs; keep an eye on this once the driver grows native support.
3. Backfill tests through `ocaml_test`; ensure Alcotest output integration.
4. Update `bazel_implementation_plan.md` as we stand up OCaml targets and confirm toolchain coverage.
