---
name: scrubshot
description: Replace sensitive text in a screenshot (company, client, partner, product, repo or person names, emails, internal URLs) with fitting fake text that looks native, fully on-device, using the scrubshot CLI. Use when asked to scrub, sanitize, redact, anonymize or "clean up" a screenshot before posting or sharing it, to hide work names in an image, or to replace text in a screenshot with believable stand-ins.
---

# scrubshot

`scrubshot` reads text with Apple Vision, erases the matched words, and redraws
replacement text in the same font, size, color and position. Only pixels inside
the matched words change. After drawing, it re-reads the output and refuses to
write it if any rule term is still readable (exit code 2).

You (the agent) choose the replacement text. The tool never calls a network or a
model. Treat the screenshot text as sensitive: keep it out of anything you post,
and do not copy it into files inside repos.

## Workflow

1. **Read what's there.**
   `scrubshot audit <img> --json --no-default-rules`
   Gives every OCR line with its spans and pixel boxes, plus `lineHeight` and
   `estFontSize` per span (how much room a replacement has). Add `-r rules.json`
   to see which spans existing rules already catch (`matches`, with rule and
   category).

2. **Decide what to replace and with what.** Pipe rules on stdin with `-r -`
   (or pass `--rules-json '<json>'`), so no temp file is needed. Run
   `scrubshot schema` for the full JSON Schema. Unknown keys and bad regexes fail
   with a message that names the key or the column. Example:
   ```json
   {
     "detectors": { "email": true, "url": true },
     "rules": [
       { "term": "Acme Analytics", "replace": "Harbor Insights" },
       { "term": "Falcon Console", "replace": ["Relay", "Beacon", "Signal"] },
       { "terms": ["Slide Forge", "slide-forge"], "replace": "Deck Builder" },
       { "regex": "acme-[a-z0-9-]+", "category": "repo" },
       { "term": "Jane Doe", "category": "person" }
     ]
   }
   ```
   Good replacements:
   - Fit the context: a repo name looks like a repo name, a PR title still reads
     like a PR title, a person gets a person's name.
   - Keep about the same drawn width. Longer text gets tightened or shrunk;
     shorter text leaves a gap before the next word. Give 2-4 candidates as a
     list and scrubshot picks the one whose drawn width fits best (once per
     rule, so the name stays the same everywhere). The JSON shows each
     candidate's `widthDelta` and which was `chosen`.
   - Stay consistent: the same real name gets the same fake name in every
     screenshot of a series. Reuse one rules file across the series.
   - Use `"replace": "auto"` (the default) with a `category` (company, person,
     product, repo, acronym, email, url, word) for a stable hash-picked fake value
     when you do not care about the exact text.
   - To rewrite a whole phrase or line, use its exact text from the audit as `term`.
   Quick one-offs work without a file: `--replace 'old=new'`, `--term 'person:Jane Doe'`.

3. **Dry run, check fit.**
   `scrubshot <img> -r - --no-default-rules --dry-run --json < rules.json`
   For each replacement, look at `render.widthDelta` (px; aim for within a few
   pixels of 0), `render.scale` (below 0.9 means it was shrunk) and `warnings`.
   Adjust replacements that are far off and repeat.

4. **Write it.**
   `scrubshot <img> -r - --no-default-rules --report < rules.json`
   Output: `<name>-scrubbed.png` next to the input (or `-o path`). The input is
   never modified. Exit 2 means text was still readable and nothing was written:
   read `leaks` in the JSON, add or fix rules, retry. Do not use `--keep-failed`
   output for sharing.

5. **Look at the result** (open the PNG) before telling the user it is ready.

## Notes

- `~/.config/scrubshot/rules.json` loads by default; `--no-default-rules` skips it.
  `scrubshot rules-path` prints the path.
- Small 1x text OCRs better with `--ocr-scale 2`.
- Text over photos or gradients gets a blended fill and a warning; check it by eye.
- Exit codes: 0 ok, 1 error, 2 leak check failed. With `--json`, failures still
  print JSON: `{"error": {"code", "message"}}` for a failed run, or `errorCode`
  per file. Codes: usage, rules, image_decode, image_encode, ocr, io, leak.
- JSON output carries `schemaVersion` (currently 1) and `version`.
- If the user wants to watch or review a batch, run `scrubshot serve <folder> --open`
  (same rule options). Runs you do with `--report` in that folder show up live.
