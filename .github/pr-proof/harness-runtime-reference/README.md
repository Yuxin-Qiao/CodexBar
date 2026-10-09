# Harness runtime reference proof

This directory contains synthetic SwiftUI/AppKit component renders of the
production Usage & Spend views. It is not installed-app, real-account, hardware
frame-rate, task-quality, or cross-provider benchmark evidence.

Fixtures use invented identities, models, paths, token counts, and prices.
The score remains an experimental runtime reference. Task performance is not
evaluated. See [the metric contract](../../../docs/harness-runtime-reference.md)
for sample eligibility, thresholds, and loading behavior.

The native render test is opt-in through `CODEXBAR_AGENT_PROFILE_UI_PROOF_DIR`.
The submission receipt records the synchronized source revision, source and
preview fingerprints, and the validation results.

- [Provider layout, English/light](providers-light.png)
- [Score basis, English/dark](rating-basis-dark.png): the production popover
  scrolls to the remaining duration card and method; this render shows its initial viewport.
- [Long synthetic amounts, Chinese/narrow](long-amounts-narrow.png)
- [Unavailable timing explanation, English/light](unavailable.png)

The renderer generated 40 images, covering both languages/themes and the three
provider widths. These four are representative images, not a claim that every
render was manually inspected. File dimensions and hashes are in
[the preview manifest](preview-manifest.json).

## Validation result

The original submission results below belong to the source fingerprints in
`validation-receipt.json`. The later performance and stability follow-up is
documented in [the audit](performance-audit.md); its source fingerprints and
complete validation outcome are recorded separately in `performance-audit-receipt.json`.

The synchronized source builds. All 16 scoring/native-render tests, 10 projection/
data/inventory tests, and 33 new-provider resource tests pass. `make check` passes
with 2,937 Swift files and zero violations; catalog and documentation checks pass.

The official full run is **not all green**: 1,644 selections in 148 groups, 146
groups passing on the first attempt, one timeout group recovered through its 12
isolated selections, and one remaining Widget headline OCR failure. Both OCR
parameter cases throw system `e5rtError` code 13, also reproduced in an isolated
run. That test is unchanged from the synchronized upstream base. No assertion is
skipped or weakened. See [the receipt](validation-receipt.json) for exact counts,
source fingerprints, and local log fingerprints.
