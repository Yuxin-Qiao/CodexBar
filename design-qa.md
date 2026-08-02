**Comparison Target**

- Source visual truth:
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-d61a0b80-5855-45df-81be-5866b387794d.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-c475cb6b-a430-4395-9f01-1d443b2ab3d6.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-f2c06b25-eeb1-4f46-ab86-80154c23557c.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-05011861-8496-4d9c-9864-4de48d51d187.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-9c6899c9-9fc8-4131-a50b-73fd69ba3a3d.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-aff7bf4c-f7db-493f-b03d-c104242fa7c6.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-286cecb4-20e8-4b7c-9c4b-b813c065d5a5.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-f5087642-7171-4aaa-b7e4-a782bbc912e9.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-d984c2e7-2c5d-4b64-b225-a9f2890c5718.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-8831ab26-5ea9-4bba-ad7b-ca2c4bf985a0.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-b3cf82b8-1e7b-4f4f-8825-cfaa82692c6e.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-31718974-22ba-4050-99b5-6355126198b9.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-2f7d0845-7d43-4002-82ba-0c3ab5632d5c.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-87f47e7e-e40e-481e-8eff-429bef7aff9e.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-7bfa21e8-6b4b-4d7a-acb7-64976e967fe3.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-0f2d65c9-1c83-4d87-a614-5bf1903f286a.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-c792e6a9-dca7-4fbc-88a8-70db4e9eff1e.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-b080cfa6-b019-40eb-bdc2-6f0364e3a96e.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-0dc00a25-f3e3-476d-9462-9b18533124d8.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-4225b455-dc8c-4d5d-b31f-426e225d2316.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-1344fb2c-0cd7-4d6f-b8f9-87ebd5cb87f3.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-3786cefd-33c0-43b7-9732-2a0e8a9551d9.png`
  - `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/codex-clipboard-b5131666-4aaa-4192-bed8-3b44b357041e.png`
- Implementation screenshot:
  `/var/folders/xh/c0sb9bl978g59ywm7f_29n6m0000gn/T/com.openai.sky.CUAService/CodexBar Screenshot 2026-07-28 at 11.55.52 PM.jpeg`
- Focused comparison:
  `/private/tmp/codexbar-subscription-comparison.png`
- Viewport: CodexBar macOS Settings > Usage & Spend > Models
- Source pixels: 1184 x 598; implementation pixels: 880 x 620
- Density normalization: the implementation subscription card was cropped and
  scaled to the source height before side-by-side comparison.
- State: 30-day range, grouped by model, token mode, subscription summary visible

**Full-view Comparison Evidence**

The signed development build compiled, passed code-sign validation, launched
successfully from this checkout, and rendered the populated Usage & Spend
settings after its background history scan. The full-window capture verifies
the 30-day controls, summary metrics, one-line subscription card, compact
144-point model chart, ranking controls, and first five ranked models together.

**Focused Region Comparison Evidence**

The focused side-by-side comparison places the supplied two-line subscription
card beside the rendered one-line implementation. Provider, plan, and amount
now share one baseline; rank and icon columns remain aligned; all six rows fit
in materially less vertical space without truncating the three available plan
names. The rendered model chart remains readable directly below the card.

Rendered and automated evidence also confirms:

- The Usage & Spend hierarchy uses one controlled optical scale: 15-point
  semibold tool titles, 14-point regular model titles, and caption-sized
  secondary metadata. This keeps the surfaces consistent while making the
  tool/model relationship immediately visible.
- Provider glyphs use an 18-point optical size inside a consistent 22-point
  alignment frame.
- Ranking and tool-card spacing was tightened without shrinking the primary
  content or changing unrelated CodexBar surfaces.
- Model rankings default to five rows, preserve ordinal numbers, and expose a
  compact token/estimated-spend sort control. Expanding and changing the sort
  are independent, persistent interactions.
- Both history charts share the same 144-point plot height, leaving more room
  for the actionable ranked and selected-day details below.
- Token and estimated-spend modes are merged into one token-category chart;
  estimated cost is shown alongside token totals in the concise day tooltip.
- The 7-day rolling-average control was removed from the primary UI because it
  obscured the exact daily values used by hover and pinned details.
- Hover now contains only date, total tokens, and estimated spend. Bucket and
  per-model splits remain in the pinned day detail below the chart.
- Daily estimated spend now follows the same hover/click contract as the model
  chart: hover is a two-value summary, click pins the date, and the tool/model
  breakdown is rendered below the chart with explicit tool-kind badges.
- Tool cards now use a true parent/child layout: the tool header owns the first
  column, the token summary aligns with the tool title, and the complete model
  list moves 48 points into a second column. Child-only dividers no longer run
  through the parent column.
- Both charts resolve clicks against screen-space day positions. Dense dates
  now form continuous nearest-day lanes, so there is no dead strip between
  adjacent active dates. The first and last lanes extend by at least 14 points
  while genuinely distant outer space stays empty.
- Both charts support click-and-drag scrubbing across dates. Hovered or pinned
  dates receive a translucent 18-point column highlight plus the persistent
  accent rule, and the chart surface uses the pointing-hand cursor.
- Model rankings now carry ordinal numbers, and pinned-day plus tool-card model
  rows use their resolved model-provider icon instead of a generic blue square
  or the containing tool's icon.
- Ranking rows use a stable two-column hierarchy. The right column owns the
  selected metric and its share: token mode renders compact token counts, while
  estimated-spend mode renders full currency values. The left subtitle contains
  only explanatory bucket or complementary-token context.
- The ranking metric control now owns the complete model-analysis state. Token
  mode charts daily token buckets with token-formatted Y-axis labels; estimated
  spend mode charts the sum of priced model costs for each day with
  currency-formatted Y-axis labels. Pinned-day details follow the same metric.
- Hover and click now resolve dates from the same rendered screen-space lanes.
  Hover adds a bounded 12-percent hysteresis zone around adjacent lane
  boundaries, while large multi-column movements still catch up immediately.
- Ranking model rows now share the pinned-day model row's system body font,
  16-point provider icon, and 20-point icon frame, with reduced row padding.
- Aggregate-only token rows label their complementary estimate explicitly, and
  the disclosure is now a compact capsule with a directional chevron instead of
  looking like an unstyled line of body text.
- Existing provider-icon, token-chart, hover-detail, and quota-warning work in
  the checkout was preserved.

**Findings**

- No actionable P0/P1/P2 visual differences remain in the requested
  subscription-density and chart-height scope.

**Comparison History**

- Iteration 1: provider glyphs were recolored using chart palette colors.
- Iteration 2: first-party assets and explicit original/template rendering modes
  replaced provider tinting; provenance is recorded in
  `docs/provider-icon-sources.md`.
- Iteration 3: semantic token stacks, exact day hover details, tool-type labels,
  and tool-level token aggregation replaced visually ambiguous single-blue
  stacks and repeated per-model metadata.
- Iteration 4: fixed 13/14-point text was replaced by the macOS semantic
  typography hierarchy, with consistent icon alignment and denser but readable
  model/tool rows.
- Iteration 5: duplicated token/spend modes and the rolling-average switch were
  removed; hover was reduced to two headline values, while ranks and
  model-provider icons were added to the scan-heavy lists.
- Iteration 6: the optical hierarchy now distinguishes 15-point tool titles from
  14-point model rows; ranking defaults to five rows and can sort by token or
  spend; both charts use a 168-point plot and the daily chart gained pinned
  date details.
- Iteration 7: model rows moved into a visibly indented child column with scoped
  dividers, and chart clicks gained bounded screen-space hit targets plus a
  stronger selected-day rule.
- Iteration 8: independent click radii were replaced with continuous
  nearest-day Voronoi lanes; click-and-drag scrubbing, a pointing-hand cursor,
  and full-column interaction highlighting were added to both charts.
- Iteration 9: ranking rows moved the active metric out of the subtitle and into
  a dedicated right-aligned value column above the percentage. Estimated spend
  gained currency formatting, token and spend context were separated, and the
  expand control gained a clear disclosure treatment.
- Iteration 10: the token/estimated-spend ranking control was promoted to a
  shared chart metric. Switching it now changes daily bar heights, Y-axis units,
  selected-day details, valid interaction dates, legend visibility, and ranking
  order together while preserving the approved hit-target behavior.
- Iteration 11: hover date selection was moved from calendar-distance lookup to
  the chart's rendered date lanes and given bounded boundary hysteresis.
  Ranking typography, provider-icon size, and row rhythm were matched to the
  pinned-day model list to reduce density and remove the visual jump.
- Iteration 12: the complete Usage & Spend surface was audited for typography
  drift. Model rows, values, tool titles, section titles, metadata, badges,
  axes, legends, disclosures, and segmented controls now use one shared
  15/14/13/12/11-point hierarchy. Model rows across pinned-day, ranking,
  daily-spend, and tool cards share the same 16-point icon in a 20-point frame.
- Iteration 13: token and estimated-spend chart modes now share one stable
  vertical structure. Both render a single accent-colored daily-total bar; the
  token-only five-item legend was removed, while the semantic input, output,
  cache, and reasoning buckets remain available in the pinned-day detail.
- Iteration 14: pinned-day model names remain 14-point primary content while
  their token splits and estimated costs move to 12-point secondary content.
- Iteration 15: subscription rows use a quieter 13-point name/value tier with
  11-point rank and plan metadata, 18-point provider marks, and tighter row
  rhythm so the provider summary no longer competes with model analysis.
  Ranking and aligned monetary values use a 14-point medium weight instead of
  semibold, and Simplified Chinese now renders the complementary metric as
  “令牌” instead of the mixed-script “token 用量”.
- Iteration 15: model ranking rows were flattened into a single scan line.
  Token sorting now shows cost as its compact complementary value, spend
  sorting shows total tokens, and the selected value plus share stay together
  at the trailing edge. Input, output, cache, and reasoning splits remain in
  the pinned-day detail instead of repeating throughout the ranking.
- Iteration 16: pinned-day model rows now default to one summary value and
  share instead of repeating every token bucket. Token mode keeps the aggregate
  bucket composition once at day level; spend mode replaces it with explicit
  priced-model coverage. Per-model token splits are available through a compact
  disclosure and reset when the selected day or metric changes.
- Iteration 17: native QA first captured a stale running process that still
  showed plan names on a second line. After quitting and relaunching the freshly
  packaged app, its background scan produced a true one-line provider/plan
  layout. The focused side-by-side comparison verifies the intended density,
  and both history charts now use a 144-point plot.
- Iteration 18: cumulative model charts now treat isolated legacy samples as
  framing noise only when they precede a gap of at least 21 days, represent no
  more than 10% of active dates, and contribute no more than 5% of either tokens
  or spend. The scan evaluates qualifying gaps from left to right, so a larger
  normal gap later in the history cannot preserve a negligible early island.
  Rankings, totals, and drill-down history retain every sample.
- Iteration 18 native capture is pending. The packaged app passed signing and
  model-domain regression tests, but the local SkyComputerUseService repeatedly
  crashed while resolving three installed CodexBar copies with the same bundle
  identifier. The attempted isolated QA copy could not be created because the
  execution approval service had reached its usage limit. Do not treat the
  pre-restart February-axis screenshot as evidence for the final build.

**Implementation Checklist**

- Capture model, tool, and daily-spend hover states from the development app.
- Verify the 15-point semibold tool title reads as one level above the 14-point
  model row without making MiniMax Code or other provider titles look oversized.
- Verify captions remain readable at default macOS text size and that long
  localized labels do not collide with values.
- Verify provider icons remain optically balanced inside their 22-point frames
  in light and dark appearance.
- Verify tooltip placement does not obscure the hovered bar at narrow and wide
  Settings window widths.
- Verify the compact tooltip shows only total tokens and estimated spend, and
  clicking a bar exposes the detailed token buckets below.
- Verify both ranking sort modes, the five-row collapsed state, expansion, and
  collapse remain readable with long localized model names.
- Verify the daily-spend click target pins the intended day and presents the
  tool/model hierarchy below without duplicating the large hover card.
- Verify the 48-point child indent remains readable at the narrowest supported
  Settings width and that long model values still retain adequate trailing room.
- Verify every position between adjacent active dates selects the intended
  nearest day, dragging scrubs without toggling dates off, and distant outer
  regions do not unexpectedly select old activity.
- Verify rank numbers align as one column and that model icons remain correct
  when the model is used through a different tool provider.
- Verify long model names leave enough room for the 84-point metric column,
  currency values retain symbols and decimals, and the disclosure capsule
  remains compact in all supported localizations.
- Verify switching to estimated spend visibly rescales the chart to currency,
  removes the token-bucket legend, and preserves the selected-day click and
  drag behavior; switching back must restore token buckets without stale dates.
- Verify slow movement near a midpoint remains on the current date until the
  pointer clearly enters the neighboring lane, while a quick sweep across
  several columns follows immediately.
- Verify ranking and pinned-day model rows now have matching optical title and
  icon sizes, and that five collapsed rows fit comfortably in the panel.
- Verify the shared 15/14/13/12/11-point hierarchy remains visually distinct
  without any default SwiftUI font leaking into model, tool, subscription,
  chart-axis, legend, badge, or disclosure content.
- Verify switching between token and estimated-spend modes leaves the ranking
  control and first ranked row at the same vertical position, and clicking a
  token bar still reveals every available semantic token bucket.
- Verify long pinned-day token splits read as secondary data rather than
  competing with model names, and that ranking currency values no longer look
  like a second set of section headings.
- Verify collapsed and expanded rankings stay one line per model in both sort
  modes, long model names truncate before the trailing value, and no token
  bucket breakdown leaks back into the ranking.
- Verify token mode shows one aggregate category breakdown, spend mode shows
  priced-model coverage instead of token categories, unpriced rows remain
  understandable, and expanding one model reveals only that model's buckets.
- Verify cumulative token and spend charts begin near the first meaningful
  activity cluster when a negligible legacy island precedes a 21+ day gap, and
  that meaningful early activity remains visible.

**Open Questions**

- Re-run the cumulative-model native capture after the desktop-control service
  is available; compare the first visible axis label against the actual first
  meaningful activity cluster.

**Follow-up Polish**

- Adjust individual optical icon sizing or row spacing only if the eventual
  native capture reveals a concrete imbalance; keep the semantic type hierarchy
  shared across providers and tools.

final result: blocked
