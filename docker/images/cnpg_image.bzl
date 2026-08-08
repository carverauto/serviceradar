"""Custom CNPG OCI image graph.

This remains the explicit exception path while the rest of docker/images
converges on shared service/release image macros.

Cross-libc invariants -- read before editing the extension layers
-----------------------------------------------------------------
The extension layers compile on the RBE executor (//build/rbe:rbe_platform ->
rbe-executor, Ubuntu 24.04, glibc 2.39) but ship on the CNPG base (Debian
bookworm, glibc 2.36). Left to itself that mismatch produces a .so which is
present, correctly named, and kills the database on startup -- both TimescaleDB
and AGE are in shared_preload_libraries, so it is never a degraded image.
It shipped once, over an existing tag, and Harbor then garbage-collected the
manifests two live clusters were pinned to. Three rules keep it fixed:

  1. Compile AND link the source extensions with `--sysroot=$ROOT_DIR` -- the
     extracted base rootfs, with libc6-dev, linux-libc-dev and libssl-dev
     overlaid in. Link-only is not enough and fails differently: the executor's
     headers redirect `strtoul` to `__isoc23_strtoul` (glibc 2.38+), which stays
     UNVERSIONED, so it slips past any version-floor check and surfaces as
     `undefined symbol: __isoc23_strtoul` at load time. Compile-only is not
     enough either -- it reintroduces `strlcpy@GLIBC_2.38` (glibc gained
     `strlcpy` in 2.38; PostgreSQL exports its own from libpgport, which is what
     the call is meant to resolve against).

  2. The base must be Debian bookworm, asserted at build time from
     /etc/os-release. Upstream's plain `18.<minor>` tag is the BULLSEYE build,
     and the overlaid postgis/pgvector debs are bookworm (`pgdg12`): mixing them
     starts Postgres and then fails `could not load library "postgis-3.so":
     libldap-2.5.so.0: cannot open shared object file`. See MODULE.bazel.

  3. Every produced .so is checked by check_extension_abi.py against that same
     sysroot, for both failure modes. Verifying an extension is PRESENT in the
     layout proves nothing -- only that it was built, not that it will load.

Also: do NOT publish over an existing tag, for the Harbor GC reason above.
"""

load("@rules_oci//oci:defs.bzl", "oci_image", "oci_load")

def declare_cnpg_image_amd64():
    """Declare the custom CNPG image and its supporting layers."""

    native.genrule(
        name = "cnpg_postgresql_18_rootfs_tar",
        srcs = ["@cloudnativepg_postgresql_18_linux_amd64//:cloudnativepg_postgresql_18_linux_amd64"],
        tools = [
            "//docker/images:export_rootfs_from_layout.py",
            "//docker/images:extract_rootfs.py",
        ],
        outs = ["cnpg_postgresql_18_rootfs.tar"],
        cmd = """
set -euo pipefail
LAYOUT_RELATIVE="$(location @cloudnativepg_postgresql_18_linux_amd64//:cloudnativepg_postgresql_18_linux_amd64)"
if [[ "$${LAYOUT_RELATIVE}" != /* ]]; then
  LAYOUT="$$(pwd)/$${LAYOUT_RELATIVE}"
else
  LAYOUT="$${LAYOUT_RELATIVE}"
fi
# Normalize the path to remove any .. or .
LAYOUT="$$(cd "$$(dirname "$${LAYOUT}")" && pwd)/$$(basename "$${LAYOUT}")"
python3 "$(location //docker/images:export_rootfs_from_layout.py)" --layout "$${LAYOUT}" --output "$@"
""",
        visibility = ["//visibility:public"],
    )

    native.genrule(
        name = "glibc_runtime_layer",
        srcs = [
            "@debian_gcc_15_base_amd64_deb//file",
            "@debian_libgcc_s1_amd64_deb//file",
            "@debian_libc6_amd64_deb//file",
        ],
        outs = ["glibc_runtime_layer.tar"],
        tools = [
            "//docker/images:overlay_deb_packages.py",
        ],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
ROOT_DIR="$${OUT_DIR}/rootfs_glibc"
OUT_TAR="$$(pwd)/$@"
mkdir -p "$${ROOT_DIR}"
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \
  "$(location @debian_gcc_15_base_amd64_deb//file)" \
  "$(location @debian_libgcc_s1_amd64_deb//file)" \
  "$(location @debian_libc6_amd64_deb//file)"
# Normalise mtimes before tarring, or this layer changes on every cache miss and drags the
# CNPG image digest with it. Two sources: `mkdir -p` stamps ROOT_DIR with wall-clock time,
# and overlay_deb_packages.py writes every file, directory and symlink without ever reading
# the deb member's mtime -- so the whole tree carries build time, not package time.
# 200001010000.00 matches rules_pkg's PORTABLE_MTIME so this agrees with layers built from
# declared files. POSIX `touch -t`; `-h` is not POSIX, hence the fallback, and it matters
# because the deb overlay creates symlinks.
find "$${ROOT_DIR}" -exec touch -h -t 200001010000.00 {} + 2>/dev/null || \
  find "$${ROOT_DIR}" -exec touch -t 200001010000.00 {} +
tar -C "$${ROOT_DIR}" -cf "$${OUT_TAR}" .
""",
    )

    native.genrule(
        name = "timescaledb_extension_layer",
        srcs = [
            ":cnpg_postgresql_18_rootfs_tar",
            "@postgresql_server_dev_18_deb//file",
            "@debian_bison_amd64_deb//file",
            "@debian_flex_amd64_deb//file",
            "@debian_libpq_dev_amd64_deb//file",
            "@debian_gcc_15_base_amd64_deb//file",
            "@debian_libgcc_s1_amd64_deb//file",
            "@debian_libc6_amd64_deb//file",
            "@debian_libc6_dev_amd64_deb//file",
            "@debian_linux_libc_dev_amd64_deb//file",
            "@debian_libssl_dev_amd64_deb//file",
            "//database/timescaledb:source_tree",
            "//docker/images:pg_config_wrapper.sh",
        ],
        outs = ["timescaledb_extension_layer.tar"],
        # Linux-only: this layer compiles the PG extension by executing Linux
        # ELF binaries (bash/make/cat) out of an extracted Debian rootfs, which
        # cannot run on macOS. Marking it incompatible makes Bazel SKIP it (and
        # its dependents, e.g. //rust/srql DB integration tests) on non-Linux
        # hosts instead of failing the build.
        target_compatible_with = ["@platforms//os:linux"],
        tools = [
            "//docker/images:check_extension_abi.py",
            "//docker/images:extract_rootfs.py",
            "//docker/images:overlay_deb_packages.py",
            "//docker/images:pg_config_rewrite.py",
            "@cmake_linux_amd64_prebuilt//:cmake_bin",
            "@cmake_linux_amd64_prebuilt//:cmake_share",
        ],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
OUT_TAR="$$(pwd)/$@"
ROOT_DIR="$${OUT_DIR}/rootfs_timescaledb"
python3 "$(location //docker/images:extract_rootfs.py)" "$(location :cnpg_postgresql_18_rootfs_tar)" "$${ROOT_DIR}"
# The overlaid debs are all bookworm (pgdg12): libc6, libc6-dev, libssl-dev, postgis,
# pgvector. Assert the base agrees, because a mismatch is close to undetectable from
# the outside. The plain `18.4` tag is a BULLSEYE build; on it Postgres starts, every
# check above passes, and PostGIS alone fails at runtime looking for libldap-2.5.so.0.
BASE_CODENAME="$$(sed -n 's/^VERSION_CODENAME=//p' "$${ROOT_DIR}/etc/os-release" 2>/dev/null || true)"
if [[ "$${BASE_CODENAME}" != "bookworm" ]]; then
  echo "CNPG base is Debian '$${BASE_CODENAME:-unknown}', expected bookworm." >&2
  echo "Every deb overlaid into this image is pgdg12/bookworm; mixing releases yields" >&2
  echo "an image that starts and then cannot load some extensions. Pin the base to" >&2
  echo "18.<minor>-system-bookworm in MODULE.bazel." >&2
  exit 1
fi
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \
  "$(location @postgresql_server_dev_18_deb//file)" \
  "$(location @debian_bison_amd64_deb//file)" \
  "$(location @debian_flex_amd64_deb//file)" \
  "$(location @debian_libpq_dev_amd64_deb//file)" \
  "$(location @debian_gcc_15_base_amd64_deb//file)" \
  "$(location @debian_libgcc_s1_amd64_deb//file)" \
  "$(location @debian_libc6_amd64_deb//file)" \
  "$(location @debian_libc6_dev_amd64_deb//file)" \
  "$(location @debian_linux_libc_dev_amd64_deb//file)" \
  "$(location @debian_libssl_dev_amd64_deb//file)"
# Portable in-place edit (GNU/BSD/macOS): no `sed -i` (its suffix handling differs
# across seds), and POSIX `[[:space:]]` instead of the GNU-only `\t`.
sed \
  -e 's|^CLANG = .*|CLANG = clang|' \
  -e 's|^with_llvm[[:space:]]*=.*|with_llvm = no|' \
  "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global" \
  > "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global.new"
mv "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global.new" \
   "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global"

# Build against the glibc this extension will RUN on, not the executor's. ROOT_DIR is
# the extracted CNPG base plus the libc6 / libc6-dev / linux-libc-dev / libssl-dev
# overlay, so it is a usable sysroot for the target: headers, libc.so linker script,
# libc.so.6, crti/crtn.
#
# BOTH compilation and linking, and each covers a failure the other does not:
#
#   link only  -> the linker stops recording `strlcpy@GLIBC_2.38` (a version the
#                 runtime cannot supply), but the executor's 2.39 headers still
#                 redirect strtoul to __isoc23_strtoul. That symbol then resolves
#                 nowhere, stays UNVERSIONED, and passes a version-floor check while
#                 failing at load with "undefined symbol: __isoc23_strtoul".
#   compile only -> the headers are right but the link still binds to the executor's
#                 libc.so.6 and reintroduces the versioned reference.
#
# The cost of compiling under the sysroot is that the executor's third-party headers
# are hidden too, which is why libssl-dev is in the overlay: TimescaleDB's
# src/net/conn_ssl.c includes <openssl/err.h>.
SYSROOT_FLAG="--sysroot=$${ROOT_DIR}"

SRC_TREE="$$(pwd)/$(execpath //database/timescaledb:source_tree)"
echo "Copying TimescaleDB sources from $${SRC_TREE}"
if [[ -d "$${OUT_DIR}/timescaledb" ]]; then
  chmod -R u+w "$${OUT_DIR}/timescaledb"
  rm -rf "$${OUT_DIR}/timescaledb"
fi
mkdir -p "$${OUT_DIR}/timescaledb"
cp -R "$${SRC_TREE}/." "$${OUT_DIR}/timescaledb"
chmod -R u+w "$${OUT_DIR}/timescaledb"
cp "$(location //docker/images:pg_config_wrapper.sh)" "$${OUT_DIR}/pg_config_wrapper_ts.sh"
chmod +x "$${OUT_DIR}/pg_config_wrapper_ts.sh"
cp "$(location //docker/images:pg_config_rewrite.py)" "$${OUT_DIR}/pg_config_rewrite.py"
# Copy while cwd is still the execroot: label expansion yields an execroot-relative
# path and the build cds into the source tree below, so it cannot be used from there.
# (Do not write the expansion macro's name in a comment either -- Bazel substitutes
# it anywhere in cmd, and a bare one fails analysis with "not defined".)
cp "$(location //docker/images:check_extension_abi.py)" "$${OUT_DIR}/check_extension_abi.py"

CMAKE_RELATIVE="$(location @cmake_linux_amd64_prebuilt//:cmake_bin)"
if [[ "$${CMAKE_RELATIVE}" != /* ]]; then
  CMAKE_BIN="$$(pwd)/$${CMAKE_RELATIVE}"
else
  CMAKE_BIN="$${CMAKE_RELATIVE}"
fi
# Don't use readlink -f - cmake needs the original path to find its modules
chmod +x "$${CMAKE_BIN}"
CMAKE_DIR="$$(dirname "$${CMAKE_BIN}")"
mkdir -p "$${OUT_DIR}/bin"
ln -sf "$${CMAKE_BIN}" "$${OUT_DIR}/bin/cmake"
export CMAKE="$${CMAKE_BIN}"
export CNPG_ROOT="$${ROOT_DIR}"
export CNPG_REAL_PG_CONFIG="$${ROOT_DIR}/usr/lib/postgresql/18/bin/pg_config"
export PATH="$${OUT_DIR}/bin:$${CMAKE_DIR}:$${ROOT_DIR}/usr/lib/postgresql/18/bin:$${ROOT_DIR}/usr/bin:/usr/bin:/bin"
export PKG_CONFIG_PATH="$${ROOT_DIR}/usr/lib/pkgconfig:$${ROOT_DIR}/usr/lib/x86_64-linux-gnu/pkgconfig"
cd "$${OUT_DIR}/timescaledb"
# MODULE_LINKER_FLAGS is the one that matters -- the extensions are built as
# MODULE libraries -- but SHARED and EXE are set too so a future target of a
# different kind does not silently lose the flag.
BUILD_FORCE_REMOVE=true ./bootstrap -DREGRESS_CHECKS=OFF -DPROJECT_INSTALL_METHOD=docker -DCMAKE_BUILD_TYPE=RelWithDebInfo -DPG_CONFIG="$${OUT_DIR}/pg_config_wrapper_ts.sh" \
  -DCMAKE_C_FLAGS="$${SYSROOT_FLAG}" \
  -DCMAKE_MODULE_LINKER_FLAGS="$${SYSROOT_FLAG}" \
  -DCMAKE_SHARED_LINKER_FLAGS="$${SYSROOT_FLAG}" \
  -DCMAKE_EXE_LINKER_FLAGS="$${SYSROOT_FLAG}"
cd build
make -j4
mkdir -p "$${OUT_DIR}/install"
make DESTDIR="$${OUT_DIR}/install_ts" install
INSTALL_PREFIX="$${OUT_DIR}/install_ts$${CNPG_ROOT}"
if [[ ! -d "$${INSTALL_PREFIX}" ]]; then
  echo "Timescale install prefix $${INSTALL_PREFIX} not found" >&2
  exit 1
fi
# Assert the sysroot actually took effect. Checking that the .so exists is not enough --
# a mis-linked TimescaleDB is present, correctly named, and stops Postgres from starting.
echo "Checking TimescaleDB glibc floor against the runtime base:"
python3 "$${OUT_DIR}/check_extension_abi.py" \
  --sysroot "$${ROOT_DIR}" \
  "$${INSTALL_PREFIX}/usr/lib/postgresql/18/lib"
# Normalise mtimes before tarring -- see glibc_runtime_layer above. Worse here than there:
# every file in this tree was just written by `make install`, so without this ALL of them
# carry build time and the layer is guaranteed to differ on each rebuild.
find "$${INSTALL_PREFIX}" -exec touch -h -t 200001010000.00 {} + 2>/dev/null || \
  find "$${INSTALL_PREFIX}" -exec touch -t 200001010000.00 {} +
tar -C "$${INSTALL_PREFIX}" -cf "$${OUT_TAR}" .
""",
    )

    native.genrule(
        name = "age_extension_layer",
        srcs = [
            ":cnpg_postgresql_18_rootfs_tar",
            "@postgresql_server_dev_18_deb//file",
            "@debian_libpq_dev_amd64_deb//file",
            "@debian_gcc_15_base_amd64_deb//file",
            "@debian_libgcc_s1_amd64_deb//file",
            "@debian_libc6_amd64_deb//file",
            "@debian_libc6_dev_amd64_deb//file",
            "@debian_linux_libc_dev_amd64_deb//file",
            "@debian_libssl_dev_amd64_deb//file",
            "//database/age:source_tree",
            "//docker/images:pg_config_wrapper.sh",
        ],
        outs = ["age_extension_layer.tar"],
        # Linux-only: this layer compiles the PG extension by executing Linux
        # ELF binaries (bash/make/cat) out of an extracted Debian rootfs, which
        # cannot run on macOS. Marking it incompatible makes Bazel SKIP it (and
        # its dependents, e.g. //rust/srql DB integration tests) on non-Linux
        # hosts instead of failing the build.
        target_compatible_with = ["@platforms//os:linux"],
        tools = [
            "//docker/images:check_extension_abi.py",
            "//docker/images:extract_rootfs.py",
            "//docker/images:overlay_deb_packages.py",
            "//docker/images:pg_config_rewrite.py",
        ],
        cmd = """
set -euo pipefail
REPO_ROOT="$$(pwd)"
OUT_DIR="$$(pwd)/$(@D)"
OUT_TAR="$$(pwd)/$@"
ROOT_DIR="$${OUT_DIR}/rootfs_age"
python3 "$(location //docker/images:extract_rootfs.py)" "$(location :cnpg_postgresql_18_rootfs_tar)" "$${ROOT_DIR}"
# The overlaid debs are all bookworm (pgdg12): libc6, libc6-dev, libssl-dev, postgis,
# pgvector. Assert the base agrees, because a mismatch is close to undetectable from
# the outside. The plain `18.4` tag is a BULLSEYE build; on it Postgres starts, every
# check above passes, and PostGIS alone fails at runtime looking for libldap-2.5.so.0.
BASE_CODENAME="$$(sed -n 's/^VERSION_CODENAME=//p' "$${ROOT_DIR}/etc/os-release" 2>/dev/null || true)"
if [[ "$${BASE_CODENAME}" != "bookworm" ]]; then
  echo "CNPG base is Debian '$${BASE_CODENAME:-unknown}', expected bookworm." >&2
  echo "Every deb overlaid into this image is pgdg12/bookworm; mixing releases yields" >&2
  echo "an image that starts and then cannot load some extensions. Pin the base to" >&2
  echo "18.<minor>-system-bookworm in MODULE.bazel." >&2
  exit 1
fi
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \
  "$(location @postgresql_server_dev_18_deb//file)" \
  "$(location @debian_libpq_dev_amd64_deb//file)" \
  "$(location @debian_gcc_15_base_amd64_deb//file)" \
  "$(location @debian_libgcc_s1_amd64_deb//file)" \
  "$(location @debian_libc6_amd64_deb//file)" \
  "$(location @debian_libc6_dev_amd64_deb//file)" \
  "$(location @debian_linux_libc_dev_amd64_deb//file)" \
  "$(location @debian_libssl_dev_amd64_deb//file)"
# Portable in-place edit (GNU/BSD/macOS): no `sed -i` (its suffix handling differs
# across seds), and POSIX `[[:space:]]` instead of the GNU-only `\t`.
sed \
  -e 's|^CLANG = .*|CLANG = clang|' \
  -e 's|^with_llvm[[:space:]]*=.*|with_llvm = no|' \
  "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global" \
  > "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global.new"
mv "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global.new" \
   "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global"

AGE_TREE="$$(pwd)/$(execpath //database/age:source_tree)"
if [[ -d "$${OUT_DIR}/age" ]]; then
  chmod -R u+w "$${OUT_DIR}/age"
  rm -rf "$${OUT_DIR}/age"
fi
mkdir -p "$${OUT_DIR}/age"
cp -R "$${AGE_TREE}/." "$${OUT_DIR}/age"
chmod -R u+w "$${OUT_DIR}/age"

cp "$${REPO_ROOT}/$(location //docker/images:pg_config_wrapper.sh)" "$${OUT_DIR}/pg_config_wrapper_age.sh"
chmod +x "$${OUT_DIR}/pg_config_wrapper_age.sh"
cp "$${REPO_ROOT}/$(location //docker/images:pg_config_rewrite.py)" "$${OUT_DIR}/pg_config_rewrite.py"
cp "$${REPO_ROOT}/$(location //docker/images:check_extension_abi.py)" "$${OUT_DIR}/check_extension_abi.py"

for tool in flex bison gperf; do
  if ! command -v "$${tool}" >/dev/null 2>&1; then
    echo "Missing required build tool: $${tool} (expected in the RBE executor image or host toolchain)" >&2
    exit 1
  fi
done

export CNPG_ROOT="$${ROOT_DIR}"
export CNPG_REAL_PG_CONFIG="$${ROOT_DIR}/usr/lib/postgresql/18/bin/pg_config"
export PATH="$${ROOT_DIR}/usr/lib/postgresql/18/bin:$${ROOT_DIR}/usr/bin:/usr/bin:/bin:$${PATH:-}"
export PKG_CONFIG_PATH="$${ROOT_DIR}/usr/lib/pkgconfig:$${ROOT_DIR}/usr/lib/x86_64-linux-gnu/pkgconfig:$${PKG_CONFIG_PATH:-}"
cd "$${OUT_DIR}/age"
# Build against the runtime's glibc rather than the executor's -- see the module
# docstring for why this has to cover compilation as well as linking. COPT is the
# right hook for a PGXS build precisely because pgxs appends it to BOTH CFLAGS and
# LDFLAGS. Setting either directly would REPLACE what pgxs derives from the server
# build.
SYSROOT_FLAG="--sysroot=$${ROOT_DIR}"
make PG_CONFIG="$${OUT_DIR}/pg_config_wrapper_age.sh" COPT="$${SYSROOT_FLAG}" FLEX=flex LEX=flex BISON=bison YACC="bison -y" -j4
mkdir -p "$${OUT_DIR}/install_age"
make PG_CONFIG="$${OUT_DIR}/pg_config_wrapper_age.sh" COPT="$${SYSROOT_FLAG}" FLEX=flex LEX=flex BISON=bison YACC="bison -y" DESTDIR="$${OUT_DIR}/install_age" install
INSTALL_PREFIX="$${OUT_DIR}/install_age$${CNPG_ROOT}"
if [[ ! -d "$${INSTALL_PREFIX}" ]]; then
  echo "AGE install prefix $${INSTALL_PREFIX} not found" >&2
  exit 1
fi
# Assert the sysroot took effect; age.so is in shared_preload_libraries, so a
# mis-linked build stops the database from starting at all.
echo "Checking AGE glibc floor against the runtime base:"
python3 "$${OUT_DIR}/check_extension_abi.py" \
  --sysroot "$${ROOT_DIR}" \
  "$${INSTALL_PREFIX}/usr/lib/postgresql/18/lib"
# Normalise mtimes before tarring -- see glibc_runtime_layer above. As with TimescaleDB,
# `make install` just wrote this whole tree at wall-clock time.
find "$${INSTALL_PREFIX}" -exec touch -h -t 200001010000.00 {} + 2>/dev/null || \
  find "$${INSTALL_PREFIX}" -exec touch -t 200001010000.00 {} +
tar -C "$${INSTALL_PREFIX}" -cf "$${OUT_TAR}" .
""",
    )

    native.genrule(
        name = "postgis_extension_layer",
        srcs = [
            "@postgresql_18_postgis_3_amd64_deb//file",
            "@postgresql_18_postgis_3_scripts_all_deb//file",
            "@postgresql_18_pgvector_amd64_deb//file",
            "@debian_libgeos_c1v5_amd64_deb//file",
            "@debian_libgeos3_11_1_amd64_deb//file",
            "@debian_libproj25_amd64_deb//file",
            "@debian_proj_data_all_deb//file",
            "@debian_libjson_c5_amd64_deb//file",
            "@debian_libprotobuf_c1_amd64_deb//file",
            "@debian_libtiff6_amd64_deb//file",
            "@debian_libcurl3_gnutls_amd64_deb//file",
            "@debian_libwebp7_amd64_deb//file",
            "@debian_liblerc4_amd64_deb//file",
            "@debian_libjbig0_amd64_deb//file",
            "@debian_libjpeg62_turbo_amd64_deb//file",
            "@debian_libdeflate0_amd64_deb//file",
            "@debian_libnghttp2_14_amd64_deb//file",
            "@debian_librtmp1_amd64_deb//file",
            "@debian_libssh2_1_amd64_deb//file",
            "@debian_libpsl5_amd64_deb//file",
            "@debian_libbrotli1_amd64_deb//file",
        ],
        outs = ["postgis_extension_layer.tar"],
        # Linux-only: this layer compiles the PG extension by executing Linux
        # ELF binaries (bash/make/cat) out of an extracted Debian rootfs, which
        # cannot run on macOS. Marking it incompatible makes Bazel SKIP it (and
        # its dependents, e.g. //rust/srql DB integration tests) on non-Linux
        # hosts instead of failing the build.
        target_compatible_with = ["@platforms//os:linux"],
        tools = [
            "//docker/images:overlay_deb_packages.py",
        ],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
OUT_TAR="$$(pwd)/$@"
ROOT_DIR="$${OUT_DIR}/rootfs_postgis"
rm -rf "$${ROOT_DIR}"
mkdir -p "$${ROOT_DIR}"
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \
  "$(location @postgresql_18_postgis_3_amd64_deb//file)" \
  "$(location @postgresql_18_postgis_3_scripts_all_deb//file)" \
  "$(location @postgresql_18_pgvector_amd64_deb//file)" \
  "$(location @debian_libgeos_c1v5_amd64_deb//file)" \
  "$(location @debian_libgeos3_11_1_amd64_deb//file)" \
  "$(location @debian_libproj25_amd64_deb//file)" \
  "$(location @debian_proj_data_all_deb//file)" \
  "$(location @debian_libjson_c5_amd64_deb//file)" \
  "$(location @debian_libprotobuf_c1_amd64_deb//file)" \
  "$(location @debian_libtiff6_amd64_deb//file)" \
  "$(location @debian_libcurl3_gnutls_amd64_deb//file)" \
  "$(location @debian_libwebp7_amd64_deb//file)" \
  "$(location @debian_liblerc4_amd64_deb//file)" \
  "$(location @debian_libjbig0_amd64_deb//file)" \
  "$(location @debian_libjpeg62_turbo_amd64_deb//file)" \
  "$(location @debian_libdeflate0_amd64_deb//file)" \
  "$(location @debian_libnghttp2_14_amd64_deb//file)" \
  "$(location @debian_librtmp1_amd64_deb//file)" \
  "$(location @debian_libssh2_1_amd64_deb//file)" \
  "$(location @debian_libpsl5_amd64_deb//file)" \
  "$(location @debian_libbrotli1_amd64_deb//file)"
EXT_DIR="$${ROOT_DIR}/usr/share/postgresql/18/extension"
ln -sf postgis-3.control "$${EXT_DIR}/postgis.control"
ln -sf postgis_raster-3.control "$${EXT_DIR}/postgis_raster.control"
ln -sf postgis_sfcgal-3.control "$${EXT_DIR}/postgis_sfcgal.control"
ln -sf postgis_topology-3.control "$${EXT_DIR}/postgis_topology.control"
ln -sf postgis_tiger_geocoder-3.control "$${EXT_DIR}/postgis_tiger_geocoder.control"
ln -sf address_standardizer-3.control "$${EXT_DIR}/address_standardizer.control"
# Normalise mtimes before tarring -- see glibc_runtime_layer above. This layer adds a third
# source on top of the deb overlay: the six `ln -sf` symlinks are created here, at build
# time, which is exactly why the `-h` form matters.
find "$${ROOT_DIR}" -exec touch -h -t 200001010000.00 {} + 2>/dev/null || \
  find "$${ROOT_DIR}" -exec touch -t 200001010000.00 {} +
tar -C "$${ROOT_DIR}" -cf "$${OUT_TAR}" .
""",
    )

    oci_image(
        name = "cnpg_image_amd64",
        base = "@cloudnativepg_postgresql_18_linux_amd64//:cloudnativepg_postgresql_18_linux_amd64",
        tars = [
            ":glibc_runtime_layer",
            ":timescaledb_extension_layer",
            ":age_extension_layer",
            ":postgis_extension_layer",
        ],
        labels = {
            "org.opencontainers.image.title": "serviceradar-cnpg",
        },
    )

    oci_load(
        name = "cnpg_image_amd64_tar",
        image = ":cnpg_image_amd64",
        repo_tags = ["registry.carverauto.dev/serviceradar/serviceradar-cnpg:local"],
    )
