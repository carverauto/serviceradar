# OCaml Remote Build Success on BuildBuddy RBE 🎉

## Summary
Successfully enabled remote execution of OCaml builds on BuildBuddy using custom Oracle Linux 9 executor with OCaml 5.2.0 toolchain.

## Problem Identified
tools_opam's `emit_ocamlsdk.c` was filtering stdlib files too aggressively:
- Only included files starting with `stdlib*` or `camlinternal*`
- **Excluded** `std_exit.*` files (required by OCaml linker)
- **Excluded** `lib*.a` runtime libraries (libasmrun.a, etc.)

## Solution Implemented

### 1. Fixed std_exit Files ✅
**File**: `third_party/vendor/tools_opam/lib/emit_ocamlsdk.c`

Modified `_symlink_ocaml_stdlib()` function to include std_exit files:
```c
bool is_std_exit = (strncmp("std_exit", direntry->d_name, 8) == 0);
if (!is_stdlib && !is_camlinternal && !is_std_exit) {
    continue;  // Skip other files
}
```

**Verification**:
```bash
ls external/tools_opam++opam+opam.ocamlsdk/stdlib/lib/std_exit.*
# Shows: std_exit.{cmi,cmx,ml,mli,o,cmo,cmt,cmti}
```

### 2. Added Runtime Libraries ✅
**Script**: `third_party/scripts/copy_stdlib_runtime.sh`

Copied runtime .a files from bundled stdlib to generated stdlib:
```bash
#!/bin/bash
SOURCE="/home/mfreeman/serviceradar/third_party/ocaml_stdlib"
TARGET="~/.cache/bazel/.../external/tools_opam++opam+opam.ocamlsdk/stdlib/lib"
cp "$SOURCE"/lib*.a "$TARGET/"
```

**Files copied**: libasmrun.a, libcamlrun.a, libthreads.a, libunix.a, etc. (17 files total)

### 3. Updated rules_ocaml Patch ✅
**File**: `third_party/patches/rules_ocaml/stdlib_env.patch`

Added stdlib/stublibs as explicit inputs to compile and link actions:
- Set `OCAMLLIB` and `CAML_LD_LIBRARY_PATH` environment variables
- Added `-I` flags for stdlib directory
- Included stdlib files in action inputs for hermetic remote execution

## Build Results

### Target 1: srql_translator_cli
```
bazel build --config=remote //ocaml/srql:srql_translator_cli
Target //ocaml/srql:srql_translator_cli up-to-date:
  bazel-out/k8-fastbuild/bin/ocaml/srql/srql_translator_cli.exe
INFO: Build completed successfully, 1 total action
```

### Target 2: test_query_engine
```
bazel build --config=remote //ocaml/srql:test_query_engine
Target //ocaml/srql:test_query_engine up-to-date:
  bazel-out/k8-fastbuild-ST-c365da17cd31/bin/ocaml/srql/test_query_engine.exe
INFO: Build completed successfully, 8 total actions
INFO: 8 processes: 4 internal, 4 remote
```

## Files Modified

1. `third_party/vendor/tools_opam/lib/emit_ocamlsdk.c` - Fixed stdlib file filtering
2. `third_party/patches/rules_ocaml/stdlib_env.patch` - Added stdlib env/inputs
3. `third_party/scripts/copy_stdlib_runtime.sh` - Runtime lib workaround
4. `third_party/ocaml_stdlib/` - Bundled complete stdlib for reference

## Next Steps

To make the solution permanent and avoid manual script execution:

1. **Option A**: Submit PR to tools_opam to include std_exit and lib*.a files
2. **Option B**: Create bazel repository_rule to automatically copy runtime libs
3. **Option C**: Build tools_opam from source with our patches applied

## Key Learnings

- obazl v3.0.0.beta uses user-defined toolchains (doesn't ship them)
- tools_opam generates stdlib repository from OPAM switch
- Remote execution requires ALL dependencies as explicit inputs
- Stdlib includes both module files AND runtime libraries
- std_exit.cmx is required by stdlib.cmxa during linking

## Relevant Documentation

- [obazl rules_ocaml](https://github.com/obazl/rules_ocaml)
- [tools_opam](https://github.com/obazl/tools_opam)
- [obazl docs](https://obazl.github.io/docs_obazl/)
- [STATUS](https://github.com/obazl/rules_ocaml/blob/main/docs/STATUS.adoc)
- [ROADMAP](https://github.com/obazl/rules_ocaml/blob/main/docs/ROADMAP.adoc)

---
**Date**: 2025-09-30
**Platform**: BuildBuddy RBE with Oracle Linux 9 + OCaml 5.2.0
**Status**: ✅ WORKING
