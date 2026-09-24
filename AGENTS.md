# Rhapsode release versioning

- For each user-visible app change, prepare exactly one new version before handing off a device build. Use `sh scripts/build.sh` for CLI builds or `sh scripts/next-build.sh` before opening/building in Xcode. Do not bump for exploratory compile-only builds or test iterations.
- Patch is the default for fixes and small refinements. Use `--minor` for a new compatible feature and `--major` for an explicitly breaking or major release change. The agent chooses the level from the work; the user does not need to run a bump command.
- Keep the resulting `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` edits in `project.yml`. Never edit the generated project or Info.plist directly, and never reuse an installable build number for different code.
