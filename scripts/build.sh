#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
change=--patch
case "${1:-}" in
    --patch|--minor|--major) change=$1; shift ;;
esac

sh "$root/scripts/next-build.sh" "$change"
cd "$root"
if [ "$#" -eq 0 ]; then
    set -- -project Rhapsode.xcodeproj -scheme Rhapsode -configuration Debug \
        -destination 'generic/platform=iOS Simulator' build
fi
exec xcodebuild "$@"
