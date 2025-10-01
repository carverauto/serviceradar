# tools_opam Vendoring: Alternative Approaches

## Problem Statement

We historically vendored 1000+ files from `obazl/tools_opam` in `third_party/vendor/tools_opam/` to carry custom patches for OCaml remote builds. That approach created a large maintenance burden and bloated the repository.

## Current Status (2025-09-30)

- ✅ `all_files` filegroup is now emitted in `stdlib/lib/BUILD.bazel` via commit `c75fdadc3cbf6230bdffe50426e24e2b38941c13` on `carverauto/tools_opam`.
- ✅ `MODULE.bazel` now pinpoints that commit directly; no local patch overlay is required.
- ✅ Vendored `third_party/vendor/tools_opam` tree was removed; the repo now depends solely on the fork via `git_override`.
- 🔜 Keep tracking upstream (obazl/tools_opam). If/when they accept the fork changes, move the override back to upstream.

## Background

### What is tools_opam?

`tools_opam` is a Bazel module extension that integrates OPAM (OCaml Package Manager) with Bazel builds. It:
- Reads OPAM package metadata (META files)
- Generates Bazel BUILD.bazel files for each OPAM package
- Creates symlinks to OPAM-installed files
- Provides `ocaml_import` rules for using OPAM packages in Bazel

### Why We Need Custom Patches

We've identified and fixed three issues in tools_opam's C code:

1. **Missing std_exit files** (`emit_ocamlsdk.c`)
   - Original code only included files starting with "stdlib" or "camlinternal"
   - OCaml linker requires `std_exit.cmx` when linking with `stdlib.cmxa`
   - **Fix**: Added filter to include `std_exit.*` files

2. **Missing runtime libraries** (`emit_ocamlsdk.c`)
   - Original code excluded `lib*.a` runtime archives (libasmrun.a, libcamlrun.a, etc.)
   - Remote execution requires these files as explicit inputs
   - **Fix**: Added filter to include `lib*.a` files in stdlib

3. **Empty archive files** (`emit_build_bazel.c`)
   - Some OPAM packages (e.g., bigarray-overlap) have 0-byte stub library files
   - Generated `cc_import` rules for empty files caused linker errors
   - **Fix**: Added `stat()` checks to skip empty `.a` files

### Current Implementation

**Location**: `third_party/vendor/tools_opam/`
**Modified files**:
- `lib/emit_ocamlsdk.c` - stdlib file filtering
- `lib/emit_build_bazel.c` - empty archive handling

**MODULE.bazel**:
```python
local_path_override(
    module_name = "tools_opam",
    path = "third_party/vendor/tools_opam",
)
```

## Alternative Approaches

### Option 1: Build Patched tools_opam in Docker Image

**Concept**: Compile our patched version of tools_opam during Docker image build, install the binary in the image, and use upstream tools_opam with the pre-built config tool.

#### Pros
- No vendored code in repo
- Patches are part of the hermetic build environment
- All remote executors use the same patched version
- Easy to update upstream (just change git commit)

#### Cons
- Docker image becomes specific to this project
- Need to rebuild Docker image when patches change
- More complex Dockerfile
- Patches live separately from the build (could get out of sync)

#### Implementation Steps

1. **Create patch files** from your current changes:
   ```bash
   cd third_party/vendor/tools_opam
   git diff lib/emit_ocamlsdk.c > /home/mfreeman/serviceradar/docker/patches/001-stdlib-files.patch
   git diff lib/emit_build_bazel.c > /home/mfreeman/serviceradar/docker/patches/002-empty-archives.patch
   ```

2. **Update `docker/Dockerfile.rbe`**:
   ```dockerfile
   # ... existing base image setup ...

   # Build patched tools_opam
   RUN git clone --depth=1 --branch=main https://github.com/obazl/tools_opam.git /tmp/tools_opam

   # Copy and apply patches
   COPY docker/patches/*.patch /tmp/patches/
   RUN cd /tmp/tools_opam \
       && git apply /tmp/patches/001-stdlib-files.patch \
       && git apply /tmp/patches/002-empty-archives.patch

   # Build the config binary
   RUN cd /tmp/tools_opam \
       && bazel build //extensions/config:config \
       && install -m 755 bazel-bin/extensions/config/config /usr/local/bin/tools_opam_config

   # Verify the binary works
   RUN /usr/local/bin/tools_opam_config --help || true

   # Clean up build artifacts
   RUN rm -rf /tmp/tools_opam /tmp/patches

   # ... rest of Dockerfile ...
   ```

3. **Update MODULE.bazel** to use upstream tools_opam:
   ```python
   # Remove local_path_override
   bazel_dep(name = "tools_opam", version = "1.0.0.beta.1")

   # OR use a specific commit from upstream:
   git_override(
       module_name = "tools_opam",
       remote = "https://github.com/obazl/tools_opam.git",
       commit = "latest-stable-commit-hash",
   )
   ```

4. **Configure tools_opam to use pre-built binary**:

   Create a custom wrapper script or set environment variable to point to the patched binary. This might require modifying how tools_opam locates its config binary (check the extension code).

5. **Rebuild and test**:
   ```bash
   docker build -t carverauto/rbe-executor:latest -f docker/Dockerfile.rbe .
   docker push carverauto/rbe-executor:latest

   # Update .bazelrc.remote with new image
   bazel clean --expunge
   bazel build --config=remote //ocaml/srql:srql_server
   ```

#### Challenges
- **Binary path discovery**: tools_opam extension needs to find the pre-built binary. May need to:
  - Set PATH to include `/usr/local/bin`
  - OR modify tools_opam extension to accept a custom binary path
  - OR override the build of `@tools_opam//extensions/config` to use a pre-built binary

- **Bazel hermeticity**: Bazel expects to build everything from source. Using a pre-built binary might require:
  - Creating a custom repository rule
  - OR using `genrule` to wrap the pre-built binary

---

### Option 2: Fork tools_opam on GitHub

**Concept**: Maintain our own fork of tools_opam with patches applied, reference it via `git_override` in MODULE.bazel.

#### Pros
- Clean separation of upstream vs our patches
- Easy to track patch history
- Can submit PRs upstream from the fork
- No vendored code
- Works seamlessly with Bazel's bzlmod system

#### Cons
- Need to maintain a fork
- Need to rebase/merge when upstream updates
- Fork could diverge from upstream

#### Implementation Steps

1. **Fork the repository on GitHub**:
   - Go to https://github.com/obazl/tools_opam
   - Click "Fork" → Create fork in `carverauto` organization
   - Clone your fork locally:
     ```bash
     git clone https://github.com/carverauto/tools_opam.git /tmp/tools_opam_fork
     cd /tmp/tools_opam_fork
     ```

2. **Create a patch branch**:
   ```bash
   git checkout -b carverauto/ocaml-5.2-stdlib-fixes
   ```

3. **Apply your patches**:
   ```bash
   # Copy the modified files from your vendored version
   cp /home/mfreeman/serviceradar/third_party/vendor/tools_opam/lib/emit_ocamlsdk.c lib/
   cp /home/mfreeman/serviceradar/third_party/vendor/tools_opam/lib/emit_build_bazel.c lib/

   # Commit with detailed message
   git add lib/emit_ocamlsdk.c lib/emit_build_bazel.c
   git commit -m "Fix OCaml 5.2 stdlib and empty archive issues

   - Include std_exit.* files in stdlib symlinks (required by stdlib.cmxa)
   - Include lib*.a runtime archives for remote execution
   - Skip empty .a files in cc_import and cc_deps generation

   These changes enable OCaml builds on remote BuildBuddy executors.

   Fixes: carverauto/serviceradar#XXX"
   ```

4. **Push to GitHub**:
   ```bash
   git push origin carverauto/ocaml-5.2-stdlib-fixes
   ```

5. **Update MODULE.bazel**:
   ```python
   bazel_dep(name = "tools_opam", version = "1.0.0.beta.1")

   git_override(
       module_name = "tools_opam",
       remote = "https://github.com/carverauto/tools_opam.git",
       commit = "abc123def456...",  # SHA of your patch commit
       # OR use branch (less stable):
       # branch = "carverauto/ocaml-5.2-stdlib-fixes",
   )
   ```

6. **Remove vendored code**:
   ```bash
   cd /home/mfreeman/serviceradar
   git rm -r third_party/vendor/tools_opam
   git commit -m "Remove vendored tools_opam, using GitHub fork instead"
   ```

7. **Test the build**:
   ```bash
   bazel clean --expunge
   bazel build //ocaml/srql:srql_server
   bazel build --config=remote //ocaml/srql:srql_server
   ```

#### Maintenance Strategy

- **Updating from upstream**:
  ```bash
  cd /tmp/tools_opam_fork
  git remote add upstream https://github.com/obazl/tools_opam.git
  git fetch upstream
  git rebase upstream/main
  git push -f origin carverauto/ocaml-5.2-stdlib-fixes
  # Update commit SHA in MODULE.bazel
  ```

- **Contributing back**:
  - Create a clean branch from upstream main
  - Cherry-pick your fixes
  - Submit PR to obazl/tools_opam
  - If accepted, switch back to upstream version

---

### Option 3: Pre-generate Repository Files in Docker Image

**Concept**: Generate all OPAM package BUILD files once in the Docker image, package them up, and use `local_repository` to reference them instead of running tools_opam's code generation at build time.

#### Pros
- Fastest build times (no code generation)
- No patching needed (generated files are correct)
- Completely hermetic (same BUILD files everywhere)
- Can work with upstream tools_opam

#### Cons
- Docker image becomes much larger (contains all generated files)
- Must rebuild image when OPAM packages change
- Generated files might not be portable across platforms
- Harder to debug (generated code is baked in)

#### Implementation Steps

1. **Generate BUILD files in Docker image**:

   Add to `docker/Dockerfile.rbe`:
   ```dockerfile
   # ... existing setup ...

   USER opam

   # Install all OPAM packages we need (already done in your Dockerfile)
   RUN eval $(opam env) && opam install -y \
       dune menhir yojson ppx_deriving lwt lwt_ppx dream.1.0.0~alpha7

   # Create directory for pre-generated Bazel files
   RUN mkdir -p /opt/opam_bazel_repos

   # Use tools_opam to generate all BUILD files
   # First, we need a temporary Bazel workspace to run the extension
   RUN mkdir -p /tmp/opam_gen && cd /tmp/opam_gen \
       && cat > MODULE.bazel <<'EOF'
   bazel_dep(name = "tools_opam", version = "1.0.0.beta.1")

   opam = use_extension("@tools_opam//extensions:opam.bzl", "opam")
   opam.deps(
       ocaml_version = "5.2.0",
       opam_version = "2.4.1",
       toolchain = "global",  # Use the system opam we just set up
       pkgs = {
           "dune": "3.17.1",
           "menhir": "20240715",
           "yojson": "2.2.2",
           "ppx_deriving": "6.0.3",
           "lwt": "5.9.0",
           "lwt_ppx": "5.9.0",
           "dream": "1.0.0~alpha7",
       }
   )
   use_repo(opam, "opam", "opam.ocamlsdk")
   # ... add all other packages you need
   EOF

   # Run bazel to trigger tools_opam extension (generates BUILD files)
   RUN cd /tmp/opam_gen \
       && bazel fetch @opam.dream//... \
       && bazel fetch @opam.lwt//... \
       # ... fetch all packages ...

   # Copy generated repositories to permanent location
   RUN OUTPUT_BASE=$(cd /tmp/opam_gen && bazel info output_base) \
       && cp -r "$OUTPUT_BASE"/external/tools_opam++opam+opam.* /opt/opam_bazel_repos/ \
       && chown -R root:root /opt/opam_bazel_repos

   # Clean up temporary workspace
   RUN rm -rf /tmp/opam_gen

   USER root
   ```

2. **Alternative: Use patched tools_opam for generation**:

   If you need your patches during generation:
   ```dockerfile
   # Copy patches into image
   COPY docker/patches/*.patch /tmp/patches/

   # Clone and patch tools_opam
   RUN git clone --depth=1 https://github.com/obazl/tools_opam.git /tmp/tools_opam \
       && cd /tmp/tools_opam \
       && git apply /tmp/patches/*.patch \
       && bazel build //extensions/config:config

   # Install patched binary temporarily
   RUN install /tmp/tools_opam/bazel-bin/extensions/config/config /usr/local/bin/tools_opam_config_patched

   # Now use this to generate BUILD files
   # (Need to configure tools_opam to use this binary - this is the tricky part)
   ```

3. **Create a repository rule in your main repo**:

   Create `third_party/opam_repos.bzl`:
   ```python
   def _pregenerated_opam_repos_impl(ctx):
       # This repository rule expects the Docker image to have
       # pre-generated files at /opt/opam_bazel_repos

       # Copy from Docker image filesystem
       ctx.symlink("/opt/opam_bazel_repos/tools_opam++opam+opam.dream", "dream")
       ctx.symlink("/opt/opam_bazel_repos/tools_opam++opam+opam.lwt", "lwt")
       # ... symlink all packages

       # Create a BUILD file that exports all packages
       ctx.file("BUILD.bazel", """
   package(default_visibility = ["//visibility:public"])
   """)

       return None

   pregenerated_opam_repos = repository_rule(
       implementation = _pregenerated_opam_repos_impl,
       local = True,
   )
   ```

4. **Use in MODULE.bazel**:
   ```python
   # Don't use tools_opam extension at all
   # Instead, use our pre-generated repos

   pregenerated_opam_repos = use_repo_rule("//third_party:opam_repos.bzl", "pregenerated_opam_repos")

   pregenerated_opam_repos(name = "opam_pregenerated")

   # Alias the packages for compatibility
   use_repo(pregenerated_opam_repos, "opam.dream", "opam.lwt", ...)
   ```

5. **Better approach - Direct symlinks**:

   Actually, the simplest approach for Option 3:

   In `docker/Dockerfile.rbe`, after generating all repos:
   ```dockerfile
   # Generate BUILD files (as above)
   # ...

   # Package them as a tarball
   RUN cd /opt && tar czf opam_bazel_repos.tar.gz opam_bazel_repos/
   ```

   In your repo, create `third_party/opam_pregenerated/BUILD.bazel`:
   ```python
   # This is a placeholder that tells Bazel about pre-generated repos
   # The actual BUILD files come from the Docker image at runtime
   ```

   Update `.bazelrc.remote`:
   ```bash
   # Mount pre-generated repos from Docker image
   build:remote --action_env=OPAM_PREGENERATED_PATH=/opt/opam_bazel_repos
   ```

   This is getting complex - you'd need custom repository rules to properly integrate this.

#### Practical Simplified Version

The most practical version of Option 3:

1. **Generate a "snapshot" of all BUILD files**:
   ```bash
   # On a machine with your OPAM setup
   cd /tmp
   git clone https://github.com/carverauto/serviceradar.git
   cd serviceradar

   # Build once to generate all repositories
   bazel build //ocaml/srql:srql_server

   # Copy all generated external repos
   OUTPUT_BASE=$(bazel info output_base)
   mkdir -p third_party/opam_snapshot
   cp -r "$OUTPUT_BASE"/external/tools_opam++opam+opam.* third_party/opam_snapshot/

   # Create a script to register them all
   cat > third_party/opam_snapshot/register.bzl <<'EOF'
   def register_opam_packages():
       native.local_repository(
           name = "opam.dream",
           path = "third_party/opam_snapshot/tools_opam++opam+opam.dream",
       )
       native.local_repository(
           name = "opam.lwt",
           path = "third_party/opam_snapshot/tools_opam++opam+opam.lwt",
       )
       # ... all other packages
   EOF
   ```

2. **Use in MODULE.bazel**:
   ```python
   # Remove tools_opam entirely
   # load("//third_party/opam_snapshot:register.bzl", "register_opam_packages")
   # register_opam_packages()

   # Or use local_path_override for each package individually
   ```

**BUT WAIT** - this doesn't work well with bzlmod. Local repositories don't integrate cleanly with module deps.

#### The Real Option 3 Solution

The cleanest Option 3 is actually:

1. **Keep the patched vendored tools_opam** (what you have now)
2. **Just accept it** - 1000 files isn't that bad if it works
3. **Mitigate the maintenance burden**:
   - Document what patches were applied (see "Patch Documentation" section below)
   - Automate sync with upstream when needed
   - Consider contributing patches back to obazl

**OR**, combine with Option 1:

1. Pre-generate BUILD files in Docker image using patched tools_opam
2. Package them up and include in image
3. Use repository_rule to symlink from image to Bazel's external directory
4. This way you get the benefits of Option 3 (fast, hermetic) with Option 1 (patched binary in image)

---

## Patch Documentation

### Patch 1: stdlib File Inclusion (emit_ocamlsdk.c)

**File**: `lib/emit_ocamlsdk.c`
**Function**: `_symlink_ocaml_stdlib()`
**Lines**: ~166-184

**Original behavior**:
```c
if (strncmp("stdlib", direntry->d_name, 6) != 0) {
    if (strncmp("camlinternal", direntry->d_name, 12) != 0) {
        continue;  // Skip file
    }
}
```

**Patched behavior**:
```c
bool is_stdlib = (strncmp("stdlib", direntry->d_name, 6) == 0);
bool is_camlinternal = (strncmp("camlinternal", direntry->d_name, 12) == 0);
bool is_std_exit = (strncmp("std_exit", direntry->d_name, 8) == 0);

// Check for lib*.a files (runtime libraries)
size_t len = strlen(direntry->d_name);
bool is_runtime_lib = (strncmp("lib", direntry->d_name, 3) == 0) &&
                      (len > 3) &&
                      (direntry->d_name[len - 2] == '.') &&
                      (direntry->d_name[len - 1] == 'a');

if (!is_stdlib && !is_camlinternal && !is_std_exit && !is_runtime_lib) {
    continue;  // Skip files that don't match any pattern
}
```

**Why needed**:
- `std_exit.cmx` is required by `stdlib.cmxa` during linking
- `lib*.a` runtime archives (libasmrun.a, etc.) are required for remote execution

---

### Patch 2: Empty Archive Handling (emit_build_bazel.c)

**File**: `lib/emit_build_bazel.c`
**Function 1**: `emit_bazel_cc_imports()` (lines ~107-127)

**Original behavior**:
```c
if (fnmatch("lib*stubs.a", direntry->d_name, 0) == 0) {
    fprintf(ostream, "cc_import(\n");
    fprintf(ostream, "    name           = \"_%s\",\n", direntry->d_name);
    fprintf(ostream, "    static_library = \"%s\",\n", direntry->d_name);
    fprintf(ostream, ")\n");
}
```

**Patched behavior**:
```c
if (fnmatch("lib*stubs.a", direntry->d_name, 0) == 0) {
    // Check if file is empty before generating cc_import
    char filepath[PATH_MAX];
    snprintf(filepath, sizeof(filepath), "%s/%s", dname, direntry->d_name);
    struct stat st;
    if (stat(filepath, &st) == 0 && st.st_size > 0) {
        fprintf(ostream, "cc_import(\n");
        fprintf(ostream, "    name           = \"_%s\",\n", direntry->d_name);
        fprintf(ostream, "    static_library = \"%s\",\n", direntry->d_name);
        fprintf(ostream, ")\n");
    }
}
```

**Function 2**: `emit_bazel_stublibs_attr()` (lines ~215-229)

**Patched behavior**: Same stat() check before adding to `cc_deps` array.

**Why needed**:
- Some OPAM packages (bigarray-overlap) have 0-byte stub library files
- Empty files are placeholders for freestanding/MirageOS builds
- Linker fails with "file is empty" error when trying to link empty archives

---

## Testing Strategy

For any option chosen, follow this testing checklist:

### Local Testing
```bash
# Clean build
bazel clean --expunge

# Test stdlib files are included
bazel build //ocaml/srql:srql_translator_cli
ls $(bazel info output_base)/external/tools_opam++opam+opam.ocamlsdk/stdlib/lib/std_exit.*
ls $(bazel info output_base)/external/tools_opam++opam+opam.ocamlsdk/stdlib/lib/lib*.a

# Verify BUILD generation skips empty files
cat $(bazel info output_base)/external/tools_opam++opam+opam.bigarray-overlap/lib/BUILD.bazel | grep -c liboverlap_freestanding_stubs
# Should be 0 (no reference to empty file)

# Test all OCaml targets build
bazel build //ocaml/srql/...
```

### Remote Testing
```bash
# Clean build with remote execution
bazel clean --expunge

# Test remote build
bazel build --config=remote //ocaml/srql:srql_server
bazel build --config=remote //ocaml/srql:test_bounded_unbounded

# Check BuildBuddy for successful execution
# Look at: https://carverauto.buildbuddy.io/invocation/...
```

### CI Testing
```bash
# Push to feature branch
git push origin feature/tools-opam-option-X

# Monitor CI build
# Verify all OCaml targets pass
```

---

## Recommendation

Based on complexity vs benefit:

1. **Short term (next sprint)**: Stay with vendored version
   - It works
   - ~1000 files is manageable
   - Focus on feature development

2. **Medium term (next quarter)**: Implement **Option 2 (GitHub Fork)**
   - Cleanest solution
   - Easy to maintain
   - Can contribute back to upstream
   - Removes vendored code from repo

3. **Long term (if patches accepted)**: Return to upstream
   - Submit PRs to obazl/tools_opam
   - Once merged, remove fork and use upstream version

---

## Quick Start Guides

### To Implement Option 1 Now

1. Extract patches:
   ```bash
   cd third_party/vendor/tools_opam
   git diff lib/emit_ocamlsdk.c > ../../docker/patches/001-stdlib-files.patch
   git diff lib/emit_build_bazel.c > ../../docker/patches/002-empty-archives.patch
   ```

2. Update Dockerfile (see Option 1 section above)

3. Build and push new image:
   ```bash
   docker build -t carverauto/rbe-executor:patched-opam -f docker/Dockerfile.rbe .
   docker push carverauto/rbe-executor:patched-opam
   ```

4. Update `.bazelrc.remote` with new image

### To Implement Option 2 Now

1. Fork on GitHub: https://github.com/obazl/tools_opam → Fork

2. Clone and apply patches:
   ```bash
   git clone https://github.com/carverauto/tools_opam.git /tmp/tools_opam_fork
   cd /tmp/tools_opam_fork
   git checkout -b carverauto/stdlib-fixes

   # Copy your patched files
   cp /home/mfreeman/serviceradar/third_party/vendor/tools_opam/lib/emit_ocamlsdk.c lib/
   cp /home/mfreeman/serviceradar/third_party/vendor/tools_opam/lib/emit_build_bazel.c lib/

   git add lib/*.c
   git commit -m "Fix OCaml 5.2 stdlib issues for remote execution"
   git push origin carverauto/stdlib-fixes
   ```

3. Update MODULE.bazel:
   ```python
   git_override(
       module_name = "tools_opam",
       remote = "https://github.com/carverauto/tools_opam.git",
       commit = "YOUR_COMMIT_SHA",
   )
   ```

4. Remove vendored code:
   ```bash
   git rm -r third_party/vendor/tools_opam
   ```

### To Implement Option 3 Now

This is the most complex - see detailed steps in Option 3 section.

---

## References

- **tools_opam GitHub**: https://github.com/obazl/tools_opam
- **obazl documentation**: https://obazl.github.io/docs_obazl/
- **Our success documentation**: `/home/mfreeman/serviceradar/REMOTE_OCAML_BUILD_SUCCESS.md`
- **Relevant commits**:
  - Initial stdlib fixes: `675f674e`, `c852be40`
  - Empty archive fix: `134dc6d4`
- **BuildBuddy RBE docs**: https://www.buildbuddy.io/docs/rbe-setup

---

## Appendix: Commands Reference

### Checking Generated Files
```bash
# Show all tools_opam generated repos
ls $(bazel info output_base)/external | grep tools_opam

# View a generated BUILD file
cat $(bazel info output_base)/external/tools_opam++opam+opam.dream/lib/BUILD.bazel

# Find which packages are using a dependency
bazel query 'deps(//ocaml/srql:srql_server)' | grep opam
```

### Debugging tools_opam
```bash
# Run tools_opam config tool manually
$(bazel info output_base)/external/tools_opam+/extensions/config/config --help

# See what opam packages are installed
opam list

# Check opam var paths
opam var lib
```

### Docker Image Management
```bash
# Build image
docker build -t carverauto/rbe-executor:TAG -f docker/Dockerfile.rbe .

# Test image locally
docker run -it --rm carverauto/rbe-executor:TAG /bin/bash

# Push to registry
docker push carverauto/rbe-executor:TAG

# Update .bazelrc.remote
# build:remote --remote_executor=grpcs://carverauto.buildbuddy.io
# build:remote --remote_default_exec_properties=container-image=docker://carverauto/rbe-executor:TAG
```

---

**Last Updated**: 2025-09-30
**Status**: Vendored version working, documented alternatives for future implementation
