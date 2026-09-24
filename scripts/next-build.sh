#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

change=${1:---patch}
case "$change" in
    --patch|--minor|--major) ;;
    *) echo "Usage: sh scripts/next-build.sh [--patch|--minor|--major]" >&2; exit 2 ;;
esac

current=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION: "\([0-9][0-9]*\)"$/\1/p' project.yml)
version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION: "\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"$/\1/p' project.yml)
case "$current" in
    ''|*[!0-9]*) echo "Expected one numeric CURRENT_PROJECT_VERSION in project.yml" >&2; exit 1 ;;
esac
case "$version" in
    ''|*' '*|*'
'*) echo "Expected one numeric MARKETING_VERSION in project.yml" >&2; exit 1 ;;
esac
major=${version%%.*}
remainder=${version#*.}
minor=${remainder%%.*}
patch=${remainder#*.}
case "$change" in
    --patch) patch=$((patch + 1)) ;;
    --minor) minor=$((minor + 1)); patch=0 ;;
    --major) major=$((major + 1)); minor=0; patch=0 ;;
esac
nextVersion=$major.$minor.$patch
next=$((current + 1))
temp=$(mktemp ./project.yml.XXXXXX)
trap 'rm -f "$temp"' EXIT HUP INT TERM
sed -e "s/^        CURRENT_PROJECT_VERSION: \"$current\"$/        CURRENT_PROJECT_VERSION: \"$next\"/" \
    -e "s/^        MARKETING_VERSION: \"$version\"$/        MARKETING_VERSION: \"$nextVersion\"/" \
    project.yml > "$temp"
mv "$temp" project.yml
trap - EXIT HUP INT TERM
xcodegen generate
echo "Prepared Rhapsode $nextVersion ($next)."
