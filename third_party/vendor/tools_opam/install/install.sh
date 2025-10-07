#!/usr/bin/env bash

bin=$HOME/.local/bin

COPTS="-C"
DOPTS="-d"

while getopts "hvb:" o; do
    case "${o}" in
        h)
            echo "Usage: bazel run @tools_opam//install:tools"
            echo "   option: -b <path> - install to <path>"
            echo "   option: -v        - verbose"
            exit
            ;;
        b)
            bin=${OPTARG}
            ;;
        v)
            COPTS="-Cv"
            DOPTS="-dv"
            ;;
        *)
            echo "Unrecognized option: ${o}"
            exit
            ;;
    esac
done
shift $((OPTIND-1))

if [[ -n "$@" ]]
then
    echo "Unrecognized arg: $@"
    exit
fi

# echo "bin: ${bin}"

# Copy-pasted from the Bazel Bash runfiles library v3.
# https://github.com/bazelbuild/bazel/blob/master/tools/bash/runfiles/runfiles.bash

# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
    source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
    source "$0.runfiles/$f" 2>/dev/null || \
    source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
    source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
    { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---

## new/new.runfiles/_main/new/templates/toolchain/adapters/local.BUILD

TDIR=$HOME/.local/share/obazl/opam

set -x

TSUB="templates/ocaml"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}

files="ocaml_bigarray.BUILD \
      ocaml_bigarray_alias.BUILD \
      ocaml_c_api.BUILD \
      ocaml_compiler-libs.BUILD \
      ocaml_compiler-libs_alias.BUILD \
      ocaml_dynlink.BUILD \
      ocaml_dynlink_alias.BUILD \
      ocaml_num.BUILD \
      ocaml_ocamldoc.BUILD \
      ocaml_rtevents.BUILD \
      ocaml_rtevents_alias.BUILD \
ocaml_runtime.BUILD \
ocaml_stdlib.BUILD \
ocaml_stdlib_alias.BUILD \
ocaml_str.BUILD \
ocaml_str_alias.BUILD \
ocaml_threads.BUILD \
ocaml_threads_alias.BUILD \
ocaml_unix.BUILD \
ocaml_unix_alias.BUILD \
ocaml_version.BUILD"

for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
TSUB="templates/ocaml/compiler_libs"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}

files="bytecomp.BUILD \
common.BUILD \
native_toplevel.BUILD \
optcomp.BUILD \
toplevel.BUILD"

for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
TSUB="templates/ocaml/runtime"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}

files="runtime_sys.BUILD runtime_vm.BUILD"
for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
TSUB="templates/platform"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}
files="arch.BUILD emitter.BUILD executor.BUILD platform.BUILD"
for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
TSUB="templates/toolchain/adapters"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}
files="local.BUILD"
for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
TSUB="templates/toolchain/adapters/linux"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}
files="x86_64.BUILD arm.BUILD"
for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
TSUB="templates/toolchain/adapters/macos"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}
files="x86_64.BUILD arm.BUILD"
for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
TSUB="templates/toolchain/profiles"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}
files="profiles.BUILD"
for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
TSUB="templates/toolchain/selectors"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}
files="local.BUILD"
for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
TSUB="templates/toolchain/selectors/linux"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}
files="x86_64.BUILD arm.BUILD"
for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
TSUB="templates/toolchain/selectors/macos"
T=${TDIR}/${TSUB}
install ${DOPTS} ${T}
files="x86_64.BUILD arm.BUILD"
for F in $files
do
    # echo "${F}"
    SRC=$(rlocation coswitch/new/${TSUB}/${F})
    # echo "SRC: ${SRC}"
    install ${COPTS} ${SRC} ${T}
done

################
WRAPPER=$(rlocation coswitch/new/templates/bazel_wrapper.sh)
install ${COPTS} ${WRAPPER} ${TDIR}/templates

################
EXE=$(rlocation tools_opam/config/pkg/pkg)
echo "EXE: ${EXE}"

## per xdg standard:
install ${DOPTS} ${bin}
install ${COPTS} ${EXE} ${bin}/coswitch
