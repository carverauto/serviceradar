#!/usr/bin/env bash
# Update the Hex cache for Bazel remote builds
# Run this script whenever Elixir dependencies change

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Updating Hex dependencies for all Elixir projects..."

# Get deps for all Elixir projects
for project in web-ng elixir/serviceradar_core elixir/serviceradar_agent_gateway elixir/datasvc; do
    if [ -d "$REPO_ROOT/$project" ] && [ -f "$REPO_ROOT/$project/mix.exs" ]; then
        echo "  -> $project"
        (cd "$REPO_ROOT/$project" && mix deps.get --quiet)
    fi
done

echo "Regenerating hex cache tarball..."
(cd ~ && tar -czf "$REPO_ROOT/build/hex_cache.tar.gz" .hex)

echo "Done! Hex cache updated at build/hex_cache.tar.gz"
echo "Size: $(ls -lh "$REPO_ROOT/build/hex_cache.tar.gz" | awk '{print $5}')"
