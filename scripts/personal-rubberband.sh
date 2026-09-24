#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ "${PERSONAL_RUBBERBAND:-}" != 1 ]; then
    echo "Refusing to build: set PERSONAL_RUBBERBAND=1 for a personal local build." >&2
    exit 2
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: PERSONAL_RUBBERBAND=1 PERSONAL_RUBBERBAND_SOURCE=/path/to/rubberband sh scripts/personal-rubberband.sh {simulator|device|prepare-device}" >&2
    exit 2
fi

target=$1
case "$target" in
    simulator)
        destination='generic/platform=iOS Simulator'
        sdk=iphonesimulator
        target_triple=arm64-apple-ios26.0-simulator
        ;;
    device|prepare-device)
        destination='generic/platform=iOS'
        sdk=iphoneos
        target_triple=arm64-apple-ios26.0
        ;;
    *)
        echo "Target must be simulator, device, or prepare-device; Release/archive builds are not supported." >&2
        exit 2
        ;;
esac

if [ -z "${PERSONAL_RUBBERBAND_SOURCE:-}" ]; then
    echo "Set PERSONAL_RUBBERBAND_SOURCE to a locally supplied Rubber Band source tree." >&2
    exit 2
fi

if ! source_dir=$(CDPATH='' cd -- "$PERSONAL_RUBBERBAND_SOURCE" 2>/dev/null && pwd); then
    echo "Rubber Band source directory not found: $PERSONAL_RUBBERBAND_SOURCE" >&2
    exit 2
fi

if [ ! -f "$source_dir/meson.build" ] || [ ! -f "$source_dir/rubberband/RubberBandStretcher.h" ]; then
    echo "Source tree must contain the Rubber Band 4.0.0 Meson project and public headers." >&2
    exit 2
fi

if ! grep -Eq "version:[[:space:]]*['\"]4\.0\.0['\"]" "$source_dir/meson.build"; then
    echo "Rubber Band source must declare project version 4.0.0 in meson.build." >&2
    exit 2
fi

for tool in meson ninja xcrun xcodegen xcodebuild; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 2
    fi
done

sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)
clang=$(xcrun --sdk "$sdk" --find clang)
clangxx=$(xcrun --sdk "$sdk" --find clang++)
ar=$(xcrun --sdk "$sdk" --find ar)
ranlib=$(xcrun --sdk "$sdk" --find ranlib)
strip=$(xcrun --sdk "$sdk" --find strip)

cross_dir=$root/.personal-rubberband/cross-files
mkdir -p "$cross_dir"
compat_header=$cross_dir/compat-size.h
printf '#include <cstddef>\nusing std::size_t;\n' > "$compat_header"
cross_path=$cross_dir/$target-arm64-ios26-sdk$sdk_version.ini
cat > "$cross_path" <<EOF
[binaries]
c = '$clang'
cpp = '$clangxx'
ar = '$ar'
ranlib = '$ranlib'
strip = '$strip'

[properties]
sys_root = '$sdk_path'
needs_exe_wrapper = true

[built-in options]
c_args = ['-target', '$target_triple', '-isysroot', '$sdk_path']
cpp_args = ['-target', '$target_triple', '-isysroot', '$sdk_path', '-include', '$compat_header']
c_link_args = ['-target', '$target_triple', '-isysroot', '$sdk_path']
cpp_link_args = ['-target', '$target_triple', '-isysroot', '$sdk_path']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF

build_target=$target
if [ "$target" = prepare-device ]; then build_target=device; fi
build_dir=$root/.personal-rubberband/$build_target-arm64-ios26-sdk$sdk_version-build
if [ -f "$build_dir/meson-private/coredata.dat" ]; then
    meson setup --reconfigure "$build_dir" "$source_dir" \
        --cross-file "$cross_path" \
        --wrap-mode=nodownload \
        -Ddefault_library=static \
        -Dauto_features=disabled
else
    meson setup "$build_dir" "$source_dir" \
        --cross-file "$cross_path" \
        --wrap-mode=nodownload \
        -Ddefault_library=static \
        -Dauto_features=disabled
fi

meson configure "$build_dir" -Dcpp_args="-target $target_triple -isysroot $sdk_path -include $compat_header"
ninja -C "$build_dir"

library=$(find "$build_dir" -type f -name 'librubberband.a' -print -quit)
if [ -z "$library" ]; then
    echo "Build completed but librubberband.a was not found in $build_dir." >&2
    exit 1
fi

architectures=$(xcrun lipo -archs "$library")
if [ -z "$architectures" ]; then
    echo "Could not determine architectures in $library." >&2
    exit 1
fi
case " $architectures " in
    *" arm64 "*) ;;
    *)
        echo "Expected an arm64 Rubber Band library, found: $architectures" >&2
        exit 1
        ;;
esac

cd "$root"
if [ "$target" = prepare-device ]; then
    overlay=$root/.personal-rubberband/project.personal.yml
    awk -v library="$library" '
        NR == 1 && $0 == "name: Rhapsode" { print "name: RhapsodePersonal"; next }
        { print }
        /^        CODE_SIGN_ENTITLEMENTS:/ {
            print "      configs:"
            print "        Debug:"
            print "          SWIFT_ACTIVE_COMPILATION_CONDITIONS: '\''$(inherited) PERSONAL_RUBBERBAND'\''"
            print "          OTHER_LDFLAGS: '\''$(inherited) -force_load \"" library "\" -lc++ -framework Accelerate'\''"
            added++
        }
        END { if (added != 1) exit 1 }
    ' "$root/project.yml" > "$overlay"
    xcodegen generate --spec "$overlay" --project-root "$root" --project "$root"
    echo "Open $root/RhapsodePersonal.xcodeproj, choose your iPhone and the Rhapsode scheme, then Run (Debug). Do not regenerate this project with the ordinary project.yml."
    exit 0
fi
xcodegen generate --spec project.yml
set -- \
    -project "$root/Rhapsode.xcodeproj" \
    -scheme Rhapsode \
    -configuration Debug \
    -destination "$destination" \
    -sdk "$sdk" \
    -derivedDataPath "$build_dir/derived-data" \
    ARCHS=arm64 \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PERSONAL_RUBBERBAND' \
    OTHER_LDFLAGS='$(inherited) -force_load "'"$library"'" -lc++ -framework Accelerate'
if [ "$target" = simulator ]; then
    set -- "$@" CODE_SIGNING_ALLOWED=NO
fi
xcodebuild "$@" build

printf 'Personal Rubber Band Debug app built for %s using iOS SDK %s and %s.\n' "$target" "$sdk_version" "$library"
