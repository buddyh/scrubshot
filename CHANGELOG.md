# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

### Added

- `scrub` replaces sensitive text in screenshots with fake text drawn in the
  same font, size, color and position. Only pixels inside matched text change.
- `audit` lists every text line Apple Vision reads, with pixel boxes.
- Rules from `~/.config/scrubshot/rules.json` or `-r` files: literal `term` and
  `terms` (with OCR-tolerant matching), `regex`, `wholeWord`, and a `replace`
  field.
- `--replace` and `--term` flags for one-off literal and stable replacements.
- Built-in `email` and `url` detectors (`--emails`, `--urls`, and `--no-` forms).
- `auto` pseudonyms: a stable fake value per category (`company`, `person`,
  `product`, `repo`, `acronym`, `email`, `url`, `word`), hash-picked so the same
  name maps to the same fake in every screenshot of a series.
- Width-aware `auto` picks: candidates are ranked by rendered width so the
  replacement stays close to the original length.
- Fail-closed verification: the output is re-read by OCR at 1x and 2x, and no
  file is written if a rule term is still readable. Exit code 2 reports the leak.
  `--keep-failed` writes an `-UNSAFE` file for debugging.
- Metadata stripping: only the color profile and DPI are kept.
- `--report` writes a JSON file beside the output with each replacement, box,
  font, color and fit. `--json` and `--dry-run` support agent workflows.
- Deterministic output: the same image and rules give byte-identical PNG and
  JSON.
- `serve` web UI for one folder, bound to 127.0.0.1 only, with side-by-side and
  slider comparisons, edit outlines, and OCR overlays. `--host-alias` adds one
  extra Host header for a local reverse proxy.
- Agent skill (`skill/scrubshot`) and `make install-skill` to link it into
  Claude Code.
