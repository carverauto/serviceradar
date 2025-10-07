#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/cut-release.sh --version <version> [options]

Options:
  --version <version>   Release version to publish (required).
  --tag-prefix <prefix> Prefix to prepend to the Git tag (default: v).
  --push                Push the branch and tag to origin when finished.
  --no-push             Do not push any refs (default).
  --dry-run             Print the actions without modifying the repository.
  --skip-changelog-check
                        Skip validation that CHANGELOG contains an entry for the version.
  -h, --help            Show this message.

The script expects the working tree to be clean aside from VERSION and CHANGELOG changes.
USAGE
}

version=""
tag_prefix="v"
push=false
dry_run=false
skip_changelog_check=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || { echo "--version requires a value" >&2; exit 1; }
            version="$2"
            shift 2
            ;;
        --version=*)
            version="${1#*=}"
            shift
            ;;
        --tag-prefix)
            [[ $# -ge 2 ]] || { echo "--tag-prefix requires a value" >&2; exit 1; }
            tag_prefix="$2"
            shift 2
            ;;
        --tag-prefix=*)
            tag_prefix="${1#*=}"
            shift
            ;;
        --push)
            push=true
            shift
            ;;
        --no-push)
            push=false
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --skip-changelog-check)
            skip_changelog_check=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$version" ]]; then
    echo "--version is required" >&2
    usage
    exit 1
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$repo_root" ]]; then
    echo "This script must be run inside the ServiceRadar repository" >&2
    exit 1
fi

cd "$repo_root"

tag="${tag_prefix}${version}"

# Ensure the working tree is clean apart from allowed files.
if [[ "$dry_run" == "false" ]]; then
    mapfile -t dirty < <(git status --porcelain)
else
    mapfile -t dirty < <(git status --porcelain)
fi
for entry in "${dirty[@]}"; do
    file=${entry:3}
    case "$file" in
        ""|"VERSION"|"CHANGELOG")
            ;;
        *)
            echo "Unexpected pending change: $file" >&2
            echo "Please commit or stash it before running this script." >&2
            exit 1
            ;;
    esac
done

if [[ "$skip_changelog_check" == "false" ]]; then
    if ! scripts/extract-changelog.py "$version" >/dev/null; then
        echo "CHANGELOG does not contain an entry for version $version" >&2
        exit 1
    fi
fi

if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] Would update VERSION file to $version"
else
    printf '%s\n' "$version" > VERSION
fi

if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] Would stage VERSION"
else
    git add VERSION
fi

if git status --porcelain -- CHANGELOG >/dev/null 2>&1 && git status --porcelain -- CHANGELOG | grep -q '.'; then
    if [[ "$dry_run" == "true" ]]; then
        echo "[dry-run] Would stage CHANGELOG"
    else
        git add CHANGELOG
    fi
fi

if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] Would create commit chore: release $tag"
else
    git commit -m "chore: release $tag"
fi

notes=""
if scripts/extract-changelog.py "$version" >/dev/null 2>&1; then
    notes=$(scripts/extract-changelog.py "$version")
else
    notes="Release $tag"
fi

if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] Would create annotated tag $tag"
else
    git tag -a "$tag" -m "$notes"
fi

if [[ "$push" == "true" ]]; then
    if [[ "$dry_run" == "true" ]]; then
        echo "[dry-run] Would push branch to origin"
        echo "[dry-run] Would push tag $tag to origin"
    else
        git push origin HEAD
        git push origin "$tag"
    fi
else
    echo "Branch and tag are ready. Push manually with:"
    echo "  git push origin HEAD"
    echo "  git push origin $tag"
fi

printf 'Release preparation complete for %s\n' "$tag"
