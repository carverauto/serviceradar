#!/usr/bin/env bash
set -euo pipefail

prefix=""
declare -a passthrough
for arg in "$@"; do
  case "$arg" in
    --prefix=*)
      prefix="${arg#--prefix=}" ;;
    *)
      passthrough+=("$arg") ;;
  esac
done

if [[ -z "${prefix}" ]]; then
  if [[ -n "${INSTALLDIR:-}" ]]; then
    prefix="${INSTALLDIR}"
  else
    echo "Missing --prefix argument" >&2
    exit 1
  fi
fi

for dotted in .dir-locals.el .editorconfig .metaconf-exclusions.txt; do
  if [[ ! -e "${dotted}" ]]; then
    : > "${dotted}"
  fi
done

if (( ${#passthrough[@]} )); then
  exec ./Configure "-Dprefix=${prefix}" "${passthrough[@]}"
else
  exec ./Configure "-Dprefix=${prefix}"
fi
