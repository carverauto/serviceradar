#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/cut-release.sh --version <version> [options]

Options:
  --version <version>   Release version to publish (required).
                        Use X.Y.Z for releases, X.Y.Z-preN for pre-releases.
  --tag-prefix <prefix> Prefix to prepend to the Git tag (default: v).
  --push                Push the current release branch to origin when finished.
                        The tag remains local until the branch is merged to staging.
  --no-push             Do not push any refs (default).
  --dry-run             Print the actions without modifying the repository.
  --prerelease          Mark as pre-release (auto-detected if version contains
                        -pre, -rc, -alpha, or -beta).
  --skip-changelog-check
                        Skip validation that CHANGELOG contains an entry for the version.
  --skip-staging        Skip staging validation (for hotfixes). Sets [skip-staging]
                        in commit message to bypass e2e tests.
  --hotfix              Alias for --skip-staging.
  -h, --help            Show this message.

Examples:
  # Standard release (requires CHANGELOG entry; pushes the branch only)
  scripts/cut-release.sh --version 1.0.71 --push

  # Pre-release for testing (no CHANGELOG required; pushes the branch only)
  scripts/cut-release.sh --version 1.0.71-pre1 --push

  # Hotfix release (skips staging e2e tests; pushes the branch only)
  scripts/cut-release.sh --version 1.0.71 --hotfix --push

After the release branch is merged to staging, run the printed ancestry check
and explicit tag-push command. Never publish the tag before that merge.

The script expects the working tree to be clean aside from VERSION, CHANGELOG,
scripts/cut-release.sh, helm/serviceradar/Chart.yaml, and the demo ArgoCD source
override changes. Dry runs skip the clean-tree check.
USAGE
}

version=""
tag_prefix="v"
push=false
dry_run=false
skip_changelog_check=false
skip_staging=false
prerelease=false

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
        --prerelease)
            prerelease=true
            shift
            ;;
        --skip-changelog-check)
            skip_changelog_check=true
            shift
            ;;
        --skip-staging|--hotfix)
            skip_staging=true
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

# Auto-detect pre-release from version string
if [[ "$version" =~ -pre[0-9]*$ ]] || \
   [[ "$version" =~ -rc[0-9]*$ ]] || \
   [[ "$version" =~ -alpha[0-9]*$ ]] || \
   [[ "$version" =~ -beta[0-9]*$ ]]; then
    prerelease=true
    echo "Detected pre-release version: $version"
fi

# Pre-releases automatically skip changelog check
if [[ "$prerelease" == "true" ]]; then
    skip_changelog_check=true
    echo "Pre-release mode: changelog check skipped"
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$repo_root" ]]; then
    echo "This script must be run inside the ServiceRadar repository" >&2
    exit 1
fi

cd "$repo_root"

tag="${tag_prefix}${version}"
demo_argocd_source_file="helm/serviceradar/.argocd-source-serviceradar-demo-prod.yaml"
current_branch=$(git symbolic-ref --quiet --short HEAD || true)

if git show-ref --verify --quiet "refs/tags/$tag"; then
    echo "Refusing to cut release: local tag $tag already exists." >&2
    exit 1
fi

if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] Would verify that origin does not already contain tag $tag"
else
    set +e
    remote_tag_output=$(git ls-remote --exit-code --tags origin "refs/tags/$tag" 2>&1)
    remote_tag_status=$?
    set -e

    case "$remote_tag_status" in
        0)
            echo "Refusing to cut release: origin already contains tag $tag." >&2
            exit 1
            ;;
        2)
            ;;
        *)
            echo "Unable to verify whether origin contains tag $tag:" >&2
            echo "$remote_tag_output" >&2
            exit "$remote_tag_status"
            ;;
    esac
fi

if [[ "$dry_run" == "false" || "$push" == "true" ]]; then
    if [[ -z "$current_branch" ]]; then
        echo "Cannot cut a release from a detached HEAD. Check out a release branch first." >&2
        exit 1
    fi
    if [[ "$current_branch" == "staging" ]]; then
        echo "Refusing to cut a release directly on staging. Create and check out a release branch first." >&2
        exit 1
    fi
fi

print_post_merge_tag_instructions() {
    echo ""
    echo "After the release branch is merged into staging, publish the tag with:"
    echo "  git fetch origin refs/heads/staging:refs/remotes/origin/staging"
    echo "  git merge-base --is-ancestor '${tag}^{commit}' refs/remotes/origin/staging && git push origin refs/tags/$tag:refs/tags/$tag"
    echo "The tag push is chained to the ancestry check and will not run if it fails."
}

# The in-place edits below use GNU sed syntax (the `-i` form and the
# `/match/{n;s/.../;}` block). BSD/macOS sed rejects both, so prefer gsed when
# present (brew install gnu-sed) and fall back to sed on Linux/CI.
SED="sed"
if command -v gsed >/dev/null 2>&1; then
    SED=gsed
fi

# Ensure the working tree is clean apart from allowed files.
if [[ "$dry_run" == "false" ]]; then
    mapfile -t dirty < <(git status --porcelain)
    for entry in "${dirty[@]}"; do
        file=${entry:3}
        case "$file" in
            ""|"VERSION"|"CHANGELOG"|"scripts/cut-release.sh"|"helm/serviceradar/Chart.yaml"|"$demo_argocd_source_file")
                ;;
            *)
                echo "Unexpected pending change: $file" >&2
                echo "Please commit or stash it before running this script." >&2
                exit 1
                ;;
        esac
    done
fi

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

# Update Helm chart version and appVersion
chart_file="helm/serviceradar/Chart.yaml"
if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] Would update $chart_file version and appVersion to $version"
else
    "$SED" -i "s/^version: .*/version: $version/" "$chart_file"
    "$SED" -i "s/^appVersion: .*/appVersion: \"$version\"/" "$chart_file"
fi

if [[ -f "$demo_argocd_source_file" ]]; then
    if [[ "$dry_run" == "true" ]]; then
        echo "[dry-run] Would update $demo_argocd_source_file global.imageTag to $tag"
    else
        "$SED" -i "/name: global.imageTag/{n;s/value: .*/value: $tag/;}" "$demo_argocd_source_file"
    fi
fi

if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] Would stage VERSION and $chart_file"
    if [[ -f "$demo_argocd_source_file" ]]; then
        echo "[dry-run] Would stage $demo_argocd_source_file"
    fi
else
    git add VERSION "$chart_file"
    if [[ -f "$demo_argocd_source_file" ]]; then
        git add "$demo_argocd_source_file"
    fi
fi

if git status --porcelain -- CHANGELOG >/dev/null 2>&1 && git status --porcelain -- CHANGELOG | grep -q '.'; then
    if [[ "$dry_run" == "true" ]]; then
        echo "[dry-run] Would stage CHANGELOG"
    else
        git add CHANGELOG
    fi
fi

commit_msg="chore: release $tag"
if [[ "$prerelease" == "true" ]]; then
    commit_msg="chore: pre-release $tag"
fi
if [[ "$skip_staging" == "true" ]]; then
    commit_msg="$commit_msg [skip-staging]"
    echo "Note: Staging validation will be skipped for this release (hotfix mode)"
fi

if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] Would create commit: $commit_msg"
else
    git commit -m "$commit_msg"
fi

notes=""
if [[ "$prerelease" == "true" ]]; then
    notes="Pre-release $tag for testing"
elif scripts/extract-changelog.py "$version" >/dev/null 2>&1; then
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
        echo "[dry-run] Would push the release branch only with:"
        echo "[dry-run]   git push origin $current_branch:refs/heads/$current_branch"
        echo "[dry-run] The tag would remain local until the release branch is merged to staging."
    else
        git push origin "$current_branch:refs/heads/$current_branch"
        echo "Release branch pushed. Open and merge its pull request before publishing the tag."
    fi
else
    echo "Branch and tag are ready locally. Push the release branch with:"
    if [[ -n "$current_branch" && "$current_branch" != "staging" ]]; then
        echo "  git push origin $current_branch:refs/heads/$current_branch"
    else
        release_branch="release/$tag"
        echo "  git switch -c $release_branch"
        echo "  git push origin $release_branch:refs/heads/$release_branch"
    fi
fi

print_post_merge_tag_instructions

if [[ "$prerelease" == "true" ]]; then
    printf 'Pre-release preparation complete for %s\n' "$tag"
    echo ""
    echo "The release workflow will automatically mark this as a pre-release on GitHub."
    echo "Pre-releases are for testing and will not be shown as the latest release."
else
    printf 'Release preparation complete for %s\n' "$tag"
fi
