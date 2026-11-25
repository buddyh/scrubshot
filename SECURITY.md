# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through GitHub's private vulnerability reporting:
go to the repository's **Security** tab and choose **Report a vulnerability**
(security advisories). Include:

- the scrubshot version (`scrubshot --version`) and macOS version,
- the steps to reproduce, using a synthetic image if possible,
- what you expected, and what happened instead.

Reports are acknowledged as soon as practical. Fixes are released in a new
version, and the advisory is published once a fix is available.

## Scope

scrubshot is a local command-line tool. It does not run a service on the
network:

- No network calls are made by the tool. OCR (Apple Vision) and drawing
  (CoreText) run on the Mac.
- The `serve` web UI binds to `127.0.0.1` only and rejects requests whose Host
  header does not match. Writes need a custom `X-Scrubshot` header, and file
  names cannot leave the chosen folder.
- `--host-alias` adds one extra Host header for a local reverse proxy. It does
  not make the server reachable from the network by itself.

Issues in the scope above are in scope for this policy. Issues in a reverse
proxy, a browser, or macOS are out of scope and should go to those projects.

## Known limitation: redaction is best effort

scrubshot is a best-effort, OCR-based redaction tool. It can miss text, and it
can misread text. Specific limits:

- Text that Vision does not read (very small, blurred, rotated, vertical, or
  heavily stylized text) is not replaced, and the fail-closed check can only
  catch what OCR reads.
- Text over photos, gradients or textures can leave visible smudges, and it
  can leave traces the OCR check does not see.
- Text in the image that matches no rule is left as it is.

Always review the output before you post or share it. Open it at full size and
check every area that held text. Do not rely on scrubshot alone for
confidential material, legal or compliance needs, or anything where a missed
term would cause harm.

Do not treat the output as proof that nothing sensitive remains.
