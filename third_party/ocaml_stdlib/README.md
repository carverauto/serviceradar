# OCaml Standard Library - DO NOT CHECK IN

This directory is used as a temporary location for copying OCaml stdlib files.

**Important**: Do not check these files into git. They are:
- Binary files (lib*.a archives)
- Environment-specific (Oracle Linux 9, OCaml 5.2.0)
- Regenerable from OPAM

## How to regenerate

These files are automatically copied from your local OPAM installation by the script:

```bash
./third_party/scripts/copy_stdlib_runtime.sh
```

This script is needed after `bazel clean --expunge` to restore runtime libraries that tools_opam doesn't yet include.

## Long-term solution

The proper fix is to update tools_opam's `lib/emit_ocamlsdk.c` to include `lib*.a` files when generating the stdlib repository. See `third_party/vendor/tools_opam/lib/emit_ocamlsdk.c` for the attempted patch.
