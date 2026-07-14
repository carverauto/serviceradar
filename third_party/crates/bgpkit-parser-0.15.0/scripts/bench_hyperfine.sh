#!/usr/bin/env bash
set -euo pipefail

# Benchmark bgpkit-parser parsing performance using hyperfine.
# Benchmarks the local target/release binary of bgpkit-parser and compares against the system PATH binary.
#
# Usage:
#   scripts/bench_hyperfine.sh [-- input-args]
#     Any arguments after -- are passed to the parser binaries before the INPUT file.
#
# Environment variables:
#   BGPKIT_BENCH_INPUT       Path to input MRT/BGP file to parse. If unset, defaults to a large RIB.
#   HYPERFINE_RUNS           Number of measurement runs (default: 3 for large RIB, else 10)
#   HYPERFINE_WARMUP         Number of warmup runs (default: 1 for large RIB, else 3)
#   LOCAL_BIN                Override local binary path (default: target/release/bgpkit-parser)
#   SYSTEM_BIN               Override system binary path; default is the first bgpkit-parser found in PATH
#   HYPERFINE_EXTRA_ARGS     Extra args passed to hyperfine (e.g., "--show-output")
#   BGPKIT_ARGS              Extra args passed to bgpkit-parser before the INPUT (e.g., "--skip-v4")
#   OUT_DIR                  Output directory for results (default: benchmarks/hyperfine)
#   BENCH_DATA_DIR           Directory to store/download inputs when BGPKIT_BENCH_INPUT is not set (default: benchmarks/test_data)
#
# Notes:
# - This script assumes the bgpkit-parser CLI accepts a single positional INPUT path.
# - If BGPKIT_BENCH_INPUT is not set, the script will:
#     1) Use benchmarks/test_data/rib-example.bz2 (download if missing from https://spaces.bgpkit.org/parser/rib-example.bz2)
#     2) Otherwise fall back to rib-example-small.bz2 in repo root or target/test_data.
#   Defaults to runs=3, warmup=1 when using the large RIB.

ROOT_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$ROOT_DIR"

# Check hyperfine availability
if ! command -v hyperfine >/dev/null 2>&1; then
  echo "ERROR: 'hyperfine' is not installed or not in PATH." >&2
  echo "Install: https://github.com/sharkdp/hyperfine or e.g. 'brew install hyperfine'" >&2
  exit 1
fi

# Build local release binary to ensure it's up to date
LOCAL_BIN_DEFAULT="target/release/bgpkit-parser"
echo "Building release binary..."
cargo build --release --features cli >/dev/null

LOCAL_BIN="${LOCAL_BIN:-$LOCAL_BIN_DEFAULT}"
if [ ! -x "$LOCAL_BIN" ]; then
  echo "ERROR: Local binary not found or not executable: $LOCAL_BIN" >&2
  exit 1
fi

# Resolve system binary (for comparison)
SYSTEM_BIN="${SYSTEM_BIN:-}"
if [ -z "$SYSTEM_BIN" ]; then
  if command -v bgpkit-parser >/dev/null 2>&1; then
    SYSTEM_BIN="$(command -v bgpkit-parser)"
  else
    SYSTEM_BIN=""
  fi
fi

# Input file detection
INPUT="${BGPKIT_BENCH_INPUT:-}"
BENCH_DATA_DIR="${BENCH_DATA_DIR:-benchmarks/test_data}"
LARGE_URL="https://spaces.bgpkit.org/parser/rib-example.bz2"
LARGE_PATH="$BENCH_DATA_DIR/rib-example.bz2"

if [ -z "$INPUT" ]; then
  # Prefer large RIB in benchmarks/test_data; download if missing
  if [ -f "$LARGE_PATH" ]; then
    INPUT="$LARGE_PATH"
  else
    mkdir -p "$BENCH_DATA_DIR"
    echo "Attempting to download large RIB to $LARGE_PATH"
    if command -v curl >/dev/null 2>&1; then
      curl -fL "$LARGE_URL" -o "$LARGE_PATH"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$LARGE_PATH" "$LARGE_URL"
    else
      echo "WARN: Neither curl nor wget available; cannot auto-download large RIB." >&2
    fi
    if [ -f "$LARGE_PATH" ]; then
      INPUT="$LARGE_PATH"
    elif [ -f "rib-example-small.bz2" ]; then
      INPUT="rib-example-small.bz2"
    elif [ -f "target/test_data/rib-example-small.bz2" ]; then
      INPUT="target/test_data/rib-example-small.bz2"
    else
      echo "ERROR: Could not locate an input file." >&2
      echo "Set BGPKIT_BENCH_INPUT to a valid file path, or place 'rib-example-small.bz2' in repo root, or run 'cargo bench' once to download test data, or install curl/wget for auto-download of the large RIB." >&2
      exit 1
    fi
  fi
fi

if [ ! -f "$INPUT" ]; then
  echo "ERROR: Input file does not exist: $INPUT" >&2
  exit 1
fi

# Determine defaults for runs/warmup based on input size choice
if [[ "$INPUT" == *"rib-example.bz2"* ]]; then
  RUNS_DEFAULT=3
  WARMUP_DEFAULT=1
else
  RUNS_DEFAULT=10
  WARMUP_DEFAULT=3
fi

# Optional args passed to parser binaries before INPUT
FORWARDED_ARGS=()
if [ $# -gt 0 ]; then
  # Support separator -- to pass arguments to the parser
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then
      shift
      break
    fi
    shift
  done
  if [ $# -gt 0 ]; then
    FORWARDED_ARGS=("$@")
  fi
fi

# Merge BGPKIT_ARGS from env
if [ -n "${BGPKIT_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  FORWARDED_ARGS=( ${BGPKIT_ARGS} "${FORWARDED_ARGS[@]}" )
fi

RUNS="${HYPERFINE_RUNS:-$RUNS_DEFAULT}"
WARMUP="${HYPERFINE_WARMUP:-$WARMUP_DEFAULT}"
EXTRA="${HYPERFINE_EXTRA_ARGS:-}"

# Output location
STAMP="$(date +%Y%m%d-%H%M%S)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nosha)"
OUT_DIR="${OUT_DIR:-benchmarks/hyperfine}"
mkdir -p "$OUT_DIR"
OUT_JSON="$OUT_DIR/${STAMP}-${SHA}.json"
OUT_MD="$OUT_DIR/${STAMP}-${SHA}.md"


echo "Benchmarking with input: $INPUT"
echo "Local bin:   $LOCAL_BIN"
if [ -n "$SYSTEM_BIN" ]; then
  echo "System bin:  $SYSTEM_BIN"
else
  echo "System bin:  (not found in PATH)"
fi
echo "Runs: $RUNS, Warmup: $WARMUP"

# Compare paths; warn if identical
IDENTICAL=0
if [ -n "$SYSTEM_BIN" ]; then
  if [ "$SYSTEM_BIN" = "$LOCAL_BIN" ]; then
    IDENTICAL=1
  fi
fi
if [ "$IDENTICAL" -eq 1 ]; then
  echo "WARN: system bgpkit-parser resolves to the same path as local: $SYSTEM_BIN" >&2
fi

# Compose commands for hyperfine
# Use explicit labels via --command-name for readability
if [ -n "$SYSTEM_BIN" ] && [ -x "$SYSTEM_BIN" ] && [ "$IDENTICAL" -eq 0 ]; then
  hyperfine \
    --warmup "$WARMUP" \
    --runs "$RUNS" \
    --export-json "$OUT_JSON" \
    ${EXTRA} \
    --command-name "local(target/release)" \
    "\"$LOCAL_BIN\" ${FORWARDED_ARGS[*]-} \"$INPUT\"" \
    --command-name "system(PATH)" \
    "\"$SYSTEM_BIN\" ${FORWARDED_ARGS[*]-} \"$INPUT\""
else
  hyperfine \
    --warmup "$WARMUP" \
    --runs "$RUNS" \
    --export-json "$OUT_JSON" \
    ${EXTRA} \
    --command-name "local(target/release)" \
    "\"$LOCAL_BIN\" ${FORWARDED_ARGS[*]-} \"$INPUT\""
fi

# Also write a small markdown summary next to the JSON for quick viewing
{
  echo "# Hyperfine: bgpkit-parser"
  echo
  echo "- Timestamp: $STAMP"
  echo "- Commit:    $SHA"
  echo "- Input:     $INPUT"
  echo "- Local:     $LOCAL_BIN"
  if [ -n "$SYSTEM_BIN" ]; then
    echo "- System:    $SYSTEM_BIN"
  fi
  echo "- Runs:      $RUNS"
  echo "- Warmup:    $WARMUP"
  echo
  echo "Command to reproduce:"
  echo "\n\tHYPERFINE_RUNS=$RUNS HYPERFINE_WARMUP=$WARMUP scripts/bench_hyperfine.sh -- ${FORWARDED_ARGS[*]-} \"$INPUT\"\n"
} > "$OUT_MD"

echo "Saved results:"
echo "  JSON: $OUT_JSON"
echo "  Note: $OUT_MD"
