# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-25

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
- Metadata stripping: the PNG keeps only image-format chunks (palette,
  transparency, color profile, gamma, DPI). Text, EXIF and other chunks are dropped.
- `--report` writes a JSON file beside the output with each replacement, box,
  font, color and fit. `--json` and `--dry-run` support agent workflows.
- Deterministic output: the same image and rules give byte-identical PNG and
  JSON.
- `serve` web UI for one folder, bound to 127.0.0.1 only, with side-by-side and
  slider comparisons, edit outlines, and OCR overlays. `--host-alias` (repeatable)
  adds an extra Host header name for a local reverse proxy.
- Agent skill (`skill/scrubshot`) and `make install-skill` to link it into
  Claude Code.
- Candidate lists: `"replace": ["Relay", "Beacon"]` picks the candidate whose
  drawn width fits best, once per rule, and reports each candidate's width.
- Rules on stdin (`-r -`) or inline (`--rules-json`), `scrubshot schema` for the
  rules JSON Schema, and strict validation that names the bad key or regex column.
- `--json` output carries `schemaVersion` and `version`; failures are JSON too,
  with stable error codes (usage, rules, image_decode, image_encode, ocr, io, leak).
- `audit --json` adds line height, an estimated font size, and match categories.
- Input handling: EXIF orientation is applied; multi-frame and over-100 MP
  images are refused; missing, empty, unreadable or undecodable files and
  unwritable output folders give clear errors.
- `serve` scales to large folders: cached thumbnails, cached state with ETags,
  bounded connections and handlers, a read timeout, a 503 with a banner while
  macOS privacy access to the folder is pending, and a paged, filterable rail.

### Performance

- Edit analysis, font placement and the verification OCR passes run in
  parallel, about 20-30% faster per screenshot with byte-identical output.
  `SCRUBSHOT_TIMING=1` prints per-phase timings.

[0.1.0]: https://github.com/buddyh/scrubshot/releases/tag/v0.1.0
