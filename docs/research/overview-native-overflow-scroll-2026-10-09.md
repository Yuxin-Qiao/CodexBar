# Native scrolling for an overflowing Overview menu

Date: 2026-10-09

## Problem and boundary

The Overview menu's wheel handler intentionally translates non-precise mouse-wheel input into provider-row highlight steps. That behavior claims the original event, so an overflowing native menu may not move its document even though AppKit's edge scroller still works. Precise trackpad input already passes through to AppKit.

This change gives an attached, vertically overflowing native menu first ownership of wheel input. It uses the existing `NSMenuScrollView` discovery and viewport geometry seams from `StatusItemController+MenuViewportRestore.swift`. Non-overflowing menus and menus whose viewport is not attached keep the existing coarse-wheel highlight behavior. Submenu and precise-input pass-through are unchanged, and `handleMenuTrackingShortcutEvent` still advances the interaction generation before routing the event so manual-refresh restoration cannot override deliberate scrolling.

Horizontal overflow alone does not trigger vertical pass-through.

## Coverage

`StatusMenuOverviewScrollTests` now attaches ordinary `NSView` fixtures beneath an `NSScrollView` document, without opening a popup or constructing a live status item. The focused cases cover:

- non-precise wheel and momentum pass-through when document height exceeds clip height;
- retained coarse highlight navigation when the viewport does not vertically overflow;
- retained coarse highlight navigation for horizontal-only overflow;
- clearing a partial wheel accumulator when viewport geometry becomes vertically overflowing;
- the existing nil-viewport, submenu, precise-input, direction, and flick-cap behavior.

## Proof limits

These geometry tests prove the production handler's claim/pass-through decision against an attached view hierarchy. They do not run AppKit's modal `NSMenuTrackingSession` or prove that a physical trackpad or mouse moves the visible production menu.

Before release, the exact built bundle still needs native proof with a provider-heavy Overview menu that exceeds the display: scroll top-to-bottom and back with a built-in precise trackpad and a non-precise/notched wheel while the pointer stays over ordinary content, then verify provider hover/click/submenus and Command-R viewport restoration. Record the observed `hasPreciseScrollingDeltas`, document height, clip height, and handled/pass-through result. The bottom edge triangle should remain optional rather than the only working path.

The installed CodexBar 0.65.0 process could not be captured through Computer Use during the preceding read-only audit, so no runtime reproduction or before/after interaction claim is made here.

## Verification checkpoint

Independent review found no source-level correctness blocker. Its suggested refinement is applied: precise input returns before viewport discovery, preserving the existing trackpad fast path. Test names now state that overflow events remain unhandled, rather than claiming observed native scrolling.

The new regression tests were run against the original upstream handler: three tests failed with six expectations, catching consumed overflow wheel/momentum events and retained partial movement. Fitted and horizontal-only cases retained their prior behavior. With the final patch restored, all 59 focused tests across Overview scrolling, switcher tracking, and viewport restoration passed. `make test` is now running; final `make check` passed with zero lint violations. Native menu interaction proof remains unavailable, so any PR remains draft.
