#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <release-tag>" >&2
  exit 1
fi

tag="$1"

if [[ "${tag}" == *$'\n'* || "${tag}" == *$'\r'* ]]; then
  echo "release tag must be a single line" >&2
  exit 1
fi

if [[ ! "${tag}" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(pre|rc|alpha|beta)(0|[1-9][0-9]*))?$ ]]; then
  echo "release tag must match vX.Y.Z or vX.Y.Z-{pre,rc,alpha,beta}N: ${tag}" >&2
  exit 1
fi

if ! git check-ref-format "refs/tags/${tag}" >/dev/null; then
  echo "release tag is not a valid Git tag ref: ${tag}" >&2
  exit 1
fi
