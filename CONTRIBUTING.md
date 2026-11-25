# Contributing

Thanks for helping with scrubshot. Please read the rules below before you open a
pull request.

## Requirements

- macOS 14 or later
- Swift 6 (Xcode or the Command Line Tools)

## Build and test

```sh
make build      # swift build -c release
make test       # swift test: unit tests plus synthetic screenshot tests
make fixtures   # regenerate Tests/Fixtures/*.png (only when a fixture change is intended)
```

Pixel tests take a minute or two. If Vision fails with `CRImageReaderError error 1`,
rerun the command once. It is an environment issue, not a code bug.

## Rules that every change must keep

1. **Local only.** No network calls, no cloud OCR, and no LLM calls in the
   pipeline. The `serve` command listens on 127.0.0.1 only.
2. **Deterministic.** The same input and rules must give byte-identical output
   PNG and JSON. Do not add randomness, Swift `Hasher` output, or time-based
   values to the output.
3. **Surgical.** Only pixels inside matched text boxes may change.
4. **Fail closed.** If a rule term can still be read after drawing, exit with
   code 2 and write nothing. Never overwrite the input file.

## Test data

- Use made-up names only, in code, tests, fixtures and docs. Examples:
  `Globex`, `Falcon Console`, `acme-billing-api`, `jordan.reyes@acme.test`.
- Never commit a real screenshot, and never copy real screenshots into the
  repository. Real screenshots are for local manual checks only.
- Do not commit output produced from a real screenshot.
- Fixtures must be generated from synthetic text.

## Commits and pull requests

- Keep commits atomic. One logical change per commit. Keep logic, wiring, UI,
  tests, docs and config changes in separate commits when they are separable.
- Use conventional commit messages (`feat:`, `fix:`, `test:`, `docs:`, `ci:`,
  `refactor:`, `chore:`, `perf:`). Write the subject in the imperative mood.
- Each commit should build and pass tests on its own.
- Fill in the pull request checklist. Confirm that tests pass, that output is
  still deterministic, and that no real data is in the change.

## Reporting bugs and requesting features

Use the issue templates. For a bug report, reproduce the problem with a
synthetic image. Do not attach real screenshots. For security problems, follow
[SECURITY.md](SECURITY.md) and do not open a public issue.
