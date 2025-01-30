#!/bin/bash
set -e

# Default to patch version bump if no argument provided
BUMP_TYPE=${1:-patch}

# Get current version
CURRENT_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
CURRENT_VERSION=${CURRENT_VERSION#v}  # Remove 'v' prefix

# Split version into major, minor, patch
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Bump version based on type
case $BUMP_TYPE in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
  *)
    echo "Invalid bump type. Use major, minor, or patch"
    exit 1
    ;;
esac

NEW_VERSION="v${MAJOR}.${MINOR}.${PATCH}"

echo "Current version: v${CURRENT_VERSION}"
echo "New version: ${NEW_VERSION}"

# Update version in setup scripts
for script in setup-deb-*.sh; do
  sed -i "s/VERSION=.*/VERSION=${NEW_VERSION}/" "$script"
done

# Stage changes
git add setup-deb-*.sh

# Create commit and tag
git commit -m "Bump version to ${NEW_VERSION}"
git tag -a "${NEW_VERSION}" -m "Release ${NEW_VERSION}"

echo "Version bumped and committed. To finish the release:"
echo "1. Review the changes"
echo "2. Push the changes: git push origin main"
echo "3. Push the tag: git push origin ${NEW_VERSION}"