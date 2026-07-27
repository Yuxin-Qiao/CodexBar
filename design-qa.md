**Comparison Target**

- Source visual truth:
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-d61a0b80-5855-45df-81be-5866b387794d.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-c475cb6b-a430-4395-9f01-1d443b2ab3d6.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-f2c06b25-eeb1-4f46-ab86-80154c23557c.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-05011861-8496-4d9c-9864-4de48d51d187.png`
- Implementation screenshot: unavailable
- Viewport: CodexBar macOS Settings > Usage & Spend > Models
- State: grouped by model and grouped by tool

**Full-view Comparison Evidence**

The signed development build compiled, passed code-sign validation, and launched
successfully from this checkout. Computer Use could read the application's menu
and invoke Settings, but its native pipe again closed before the Settings window
response. A fresh Computer Use runtime failed the same way while the CodexBar
process remained running, so no safe rendered screenshot was available.

**Focused Region Comparison Evidence**

Rendered comparison is blocked. Static and automated evidence confirms:

- Gemini, Claude, Kimi, and Antigravity load first-party original-color PNGs.
- MiniMax loads the gradient waveform extracted from its first-party brand package.
- Cursor loads the official `CUBE_2D_LIGHT.svg` geometry.
- Original-color icons are not marked as AppKit template images.
- Monochrome official marks follow the foreground color for light/dark contrast.
- Chart-series colors no longer recolor provider marks.
- Token bars now encode input, cache read, cache write, output, and reasoning
  categories with a matching legend.
- Daily spend hover data carries the exact day, tool type, model, token count,
  and estimated cost.
- Tool cards aggregate token buckets once at tool level and keep per-model rows
  compact.

Static inspection and passing tests are not substitutes for visual comparison.

**Findings**

- [P2] Final native rendering remains visually unverified
  - Location: Usage & Spend model chart, tool cards, and daily-spend hover.
  - Evidence: the signed app launched, but Computer Use closed its native pipe
    while opening Settings.
  - Impact: final small-size antialiasing and row alignment cannot be assessed
    from a captured implementation screenshot.
  - Fix: capture grouped-by-model and grouped-by-tool states once the native
    accessibility bridge is stable.

**Comparison History**

- Iteration 1: provider glyphs were recolored using chart palette colors.
- Iteration 2: first-party assets and explicit original/template rendering modes
  replaced provider tinting; provenance is recorded in
  `docs/provider-icon-sources.md`.
- Iteration 3: semantic token stacks, exact day hover details, tool-type labels,
  and tool-level token aggregation replaced visually ambiguous single-blue
  stacks and repeated per-model metadata.

**Implementation Checklist**

- Capture model, tool, and daily-spend hover states from the development app.
- Verify current Gemini multicolor star, Kimi blue dot, MiniMax gradient, Claude
  coral mark, and Antigravity full-color mark at 20 points.
- Verify Cursor and OpenAI remain legible in light and dark appearance.
- Verify tooltip placement does not obscure the hovered bar at narrow and wide
  Settings window widths.

**Open Questions**

- None about intended behavior; only rendered native evidence is missing.

**Follow-up Polish**

- Adjust per-icon optical sizing only if the eventual native capture shows a
  first-party asset appearing materially smaller than its peers.

final result: blocked
