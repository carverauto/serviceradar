#!/usr/bin/env bash
set -e
set -o pipefail

function _error_echo {
	echo -e "\e[0;31merror: ${1}\e[0m"
}

git_status=$(git status --porcelain)
if [[ ! -z $git_status ]]; then
	_error_echo "uncommitted state:"
	git status -s
	_error_echo "please commit or tidy uncommitted state before running release"
	exit 1
fi

# takes the tag as an argument (e.g. v0.1.0)
if [[ ! -n "$1" ]]; then
	_error_echo "please provide either a semver release type (major, minor, patch) or a tag of the form v#.#.#"
	exit 1
fi

current_version=$(cargo metadata --offline --format-version 1 |jq -r '.packages.[] | select(.name == "cookie_store") | .version')
IFS='.' read -r major minor patch <<< "${current_version}"

echo "current_version: ${major}.${minor}.${patch}"

pre_1=false
if (( major == 0 )); then
	pre_1=true
fi
if $pre_1; then
	echo "pre-1.0 release series"
fi

release_type="${1}"
if [[ "${release_type}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
	release_tag="${release_type#v}"
	echo "explicit version specified: ${release_tag}"
	IFS='.' read -r explicit_major explicit_minor explicit_patch <<< "${release_tag}"
	if (( explicit_major < major )); then
		_error_echo "cannot specify explicit major version '${explicit_major}' < existing major version '${major}'"
		exit 1
	elif (( explicit_major > major )); then
		release_type="major"
	elif (( explicit_minor < minor )); then
	  _error_echo "cannot specify explicit minor version '${explicit_minor}' < existing minor version '${minor}'"
	  exit 1
	elif (( explicit_minor > minor )); then
	  release_type="minor"
	elif (( explicit_patch < patch )); then
	  _error_echo "cannot specify explicit patch version '${explicit_patch}' < existing patch version '${patch}'"
	  exit 1
	elif (( explicit_patch > patch )); then
	  release_type="patch"
	else
	  _error_echo "explicit tag matches existing tag"
	  exit 1
  fi
else
  case "${release_type}" in
  major)
	  if $pre_1; then
	    minor=$((minor + 1))
	    patch=0
  	else
	    major=$((major + 1))
	    minor=0
	    patch=0
    fi;;
  minor)
    if $pre_1; then
    	patch=$((patch + 1))
  	else
	    minor=$((minor + 1))
	    patch=0
    fi;;
  patch)
    patch=$((patch + 1));;
  *)
		echo -e "\e[31merror: invalid release_type='${release_type}' please provide either a semver release type (major, minor, patch) or a tag of the form v#.#.#\e[0m"
		exit 1;;
	esac
  release_tag="${major}.${minor}.${patch}"
fi

echo "release_type=${release_type}"
echo "release_tag=${release_tag}"

cargo semver-checks --release-type "${release_type}"

echo "semver checks passed, creating release"

# update the version
msg="# managed by release.sh"
sed "s/^version = .* $msg$/version = \"${release_tag}\" $msg/" -i Cargo.toml
# update the changelog
git cliff --sort newest --unreleased --tag "v${release_tag}" --prepend CHANGELOG.md
git diff
echo -e -n "\e[33mProceed? \e[0m"
read -r -n 1 -s -p "[y/N] " proceed
echo
if [[ "${proceed}" != "y" ]]; then
	echo -e "\e[31maborting; leaving dirty state:\e[0m"
	git status -s
	exit
fi
git add -A
git commit -m "chore(release): prepare for v${release_tag}"
git show
# generate a changelog for the tag message
export GIT_CLIFF_TEMPLATE="\
  {% for group, commits in commits | group_by(attribute=\"group\") %}
  {{ group | upper_first }}\
    {% for commit in commits %}
    - {% if commit.breaking %}(breaking) {% endif %}{{ commit.message | upper_first }} ({{ commit.id | truncate(length=7, end=\"\") }})\
      {% endfor %}
      {% endfor %}"
changelog=$(git cliff --sort newest --unreleased --strip all)
git tag "v${release_tag}" -m "Release $1" -m "$changelog"
git show -q "v${release_tag}"
