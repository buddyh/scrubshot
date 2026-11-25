# Releasing scrubshot

This checklist covers a tagged release and the one-time steps before the
repository is made public.

## Release checklist

1. **Bump the version.** Change `let version = "X.Y.Z"` in
   `Sources/scrubshot/main.swift`. Check that `scrubshot --version` prints the
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

## Before making the repo public

This repository is private. Do not change its visibility to public. Publish a
new public repository with a fresh history instead.

- **(a) Use fresh history.** Early commits in this repository contain test
  strings that were later replaced with made-up names. Those strings remain in
  the git history even though the current tree is clean. Make the public
  repository from a squashed snapshot of the tree:
  ```sh
  git checkout --orphan public
  git commit -m "chore: initial public release"
  ```
  Then push that single commit to a NEW public repository. Do not push this
  repository's history to it.
- **(b) Scan for secrets and real names.** Run gitleaks on the tree that will
  be published, and search for real company, client, and people names:
  ```sh
  gitleaks dir --no-banner --redact .
  ```
  Fix every finding. Do not allow an exception without a reason in the commit.
- **(c) Confirm the images are synthetic.** Check every image in `docs/` and
  every fixture under `Tests/Fixtures/`. They must be generated from made-up
  text. Do not publish an image that came from a real screenshot.
