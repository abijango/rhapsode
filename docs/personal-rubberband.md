# Personal Rubber Band build

This is an opt-in, local prototype build for personal evaluation only. It does
not add Rubber Band to `project.yml`, change the ordinary `scripts/build.sh`
flow, or create an Xcode app Release/archive path. No source or compiled vendor
binary is checked in. The script builds the local static library and then builds
the Rhapsode app in Debug with `PERSONAL_RUBBERBAND` enabled and the matching
library plus `libc++` linked. Do not use the result for distribution or
shipping; resolve licensing and integration approval separately first.

In the personal build, Rubber Band R3 is the default speed engine, including
when silence trimming is off. Settings → SmartSpeech → Playback speed engine
can switch back to Apple's speed engine. The choice persists across launches;
switching engines reloads the current audio stream at its source position.
Ordinary builds retain Apple's engine and do not show this setting.

Supply an already-present Rubber Band 4.0.0 source tree. The script checks the
version declared by its Meson project and does not clone, download, or modify
the source tree. It needs the upstream Meson project, public
`rubberband/RubberBandStretcher.h` header, Meson, Ninja, XcodeGen, and Xcode
command-line tools (`xcrun`, `xcodebuild`). It does not use the upstream iOS
cross files: each run generates a private arm64 Meson cross file from the
selected Xcode SDK and Clang paths reported by `xcrun`.

Run one target at a time from the repository root:

```sh
PERSONAL_RUBBERBAND=1 \
PERSONAL_RUBBERBAND_SOURCE=/absolute/path/to/rubberband \
sh scripts/personal-rubberband.sh simulator

PERSONAL_RUBBERBAND=1 \
PERSONAL_RUBBERBAND_SOURCE=/absolute/path/to/rubberband \
sh scripts/personal-rubberband.sh device

# Prepare a dedicated Xcode project for Run on your connected iPhone:
PERSONAL_RUBBERBAND=1 \
PERSONAL_RUBBERBAND_SOURCE=/absolute/path/to/rubberband \
sh scripts/personal-rubberband.sh prepare-device
```

The first command builds for generic iOS Simulator; the second builds for
generic iOS device. Each selects the SDK with `xcrun`, generates an arm64
toolchain using the matching simulator/device target triple and iOS 26.0
deployment minimum, then builds the static library with Meson optional
features disabled and wrap downloads forbidden. It generates the ordinary
project from `project.yml` and invokes `xcodebuild` for **Debug** only, passing
`PERSONAL_RUBBERBAND` to Swift and linking the arm64 `librubberband.a` plus
`libc++`. Simulator code signing is disabled; device signing keeps Xcode's
default so the result can be installable when a signing identity and profile
are configured locally. It does not change `project.yml`, bump the app version,
package an XCFramework, install the app, or accept a `Release`, archive, or
distribution mode. Cross files and build artifacts stay under the ignored
`.personal-rubberband/` directory, with separate target/SDK build trees.

`prepare-device` builds the local device library and generates the ignored
`RhapsodePersonal.xcodeproj` from the tracked `project.yml` plus local Debug-only
R3 build settings. Open **that project**, select the **Rhapsode** scheme and
your iPhone, and choose **Run** in Xcode. A normal `Rhapsode.xcodeproj` build
will not contain R3. The personal project uses the same app bundle identifier,
so Xcode can update the app on your phone without deleting its library. Do not
run `xcodegen generate` against the ordinary spec in place of this preparation,
and do not Archive the personal project. Prepare a fresh app version before
installing code changes; compilation-only and simulator tests do not need one.

To rebuild against a different source tree, remove only the matching generated
build directory under `.personal-rubberband/` before running the command again;
Meson reconfigures an existing build tree against its original source path.
