# Releasing scrubshot

This checklist covers a tagged release.

## Release checklist

1. **Bump the version.** Change `let version = "X.Y.Z"` in
   `Sources/scrubshot/Serve.swift`. Check that `scrubshot --version` prints the
   new value after a build.
2. **Update the changelog.** Move items from Unreleased into a new
   `## [X.Y.Z] - YYYY-MM-DD` section in `CHANGELOG.md`, and update the link
   references at the bottom of the file if you use them.
3. **Run the tests.**
   ```sh
   make test
   ```
   CI must also be green on the commit you tag.
4. **Commit the release.** Use one commit for the version bump and changelog,
   for example `chore: release X.Y.Z`.
5. **Tag the commit.**
   ```sh
   git tag -a vX.Y.Z -m "scrubshot X.Y.Z"
   git push origin main vX.Y.Z
   ```
6. **Build the universal release binary.**
   ```sh
   swift build -c release --arch arm64 --arch x86_64
   BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/scrubshot"
   ```
   SwiftPM picks the output folder, so take the path from `--show-bin-path`. Check it with
   `lipo -archs` (it should list `arm64 x86_64`) and run `--version`.
7. **Package and checksum the binary.**
   ```sh
   mkdir -p artifacts/release
   cp "$BIN" artifacts/release/scrubshot-X.Y.Z-macos-universal
   shasum -a 256 artifacts/release/scrubshot-X.Y.Z-macos-universal > artifacts/release/scrubshot-X.Y.Z-macos-universal.sha256
   ```
   The `artifacts/` folder is git-ignored, so the release files are not
   committed.
8. **Create the GitHub release.** Create a release from tag `vX.Y.Z`, paste the
   changelog section as the notes, and attach the binary and the `.sha256`
   file. Put the SHA-256 value in the notes as well.
