#!/bin/bash

# bump-version.sh - Helper script to bump VERSION file

set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${BASE_DIR}/VERSION"

usage() {
    echo "Usage: $0 [major|minor|patch|<version>]"
    echo ""
    echo "Examples:"
    echo "  $0 patch          # 1.0.52 -> 1.0.53"
    echo "  $0 minor          # 1.0.52 -> 1.1.0"
    echo "  $0 major          # 1.0.52 -> 2.0.0"
    echo "  $0 1.2.3          # Set to specific version"
    echo ""
    echo "Current version: $(cat $VERSION_FILE 2>/dev/null || echo 'VERSION file not found')"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

# Read current version
if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: VERSION file not found at $VERSION_FILE"
    exit 1
fi

CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
echo "Current version: $CURRENT_VERSION"

# Parse version components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$1" in
    major)
        NEW_VERSION="$((MAJOR + 1)).0.0"
        ;;
    minor)
        NEW_VERSION="${MAJOR}.$((MINOR + 1)).0"
        ;;
    patch)
        NEW_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
        ;;
    *.*.*)
        # Direct version specified
        NEW_VERSION="$1"
        ;;
    *)
        echo "Error: Invalid argument '$1'"
        usage
        ;;
esac

echo "New version: $NEW_VERSION"
echo -n "$NEW_VERSION" > "$VERSION_FILE"

# Update components.json if it exists (for backward compatibility)
COMPONENTS_FILE="${BASE_DIR}/packaging/components.json"
if [ -f "$COMPONENTS_FILE" ]; then
    echo "Updating components.json..."
    # Use a temp file to avoid issues with jq in-place editing
    jq --arg version "$NEW_VERSION" 'map(if .version then .version = $version else . end)' "$COMPONENTS_FILE" > "${COMPONENTS_FILE}.tmp"
    mv "${COMPONENTS_FILE}.tmp" "$COMPONENTS_FILE"
fi

echo ""
echo "Version bumped to $NEW_VERSION"
echo ""
echo "Next steps:"
echo "1. Commit: git add VERSION packaging/components.json && git commit -m 'Bump version to $NEW_VERSION'"
echo "2. Tag: git tag v$NEW_VERSION"
echo "3. Push: git push && git push --tags"