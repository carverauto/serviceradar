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
  echo "Missing --prefix argument" >&2
  exit 1
fi

if (( ${#passthrough[@]} )); then
  exec ./Configure "-Dprefix=${prefix}" "${passthrough[@]}"
else
  exec ./Configure "-Dprefix=${prefix}"
fi
