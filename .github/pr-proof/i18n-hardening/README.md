# Localization hardening evidence

This supplements [upstream PR #4223](https://github.com/steipete/CodexBar/pull/4223), based on its `982f815a38acf9c51a4dd0ebec93f39cb96656b8` head. It targets that author branch so the review contains only these fixes.

The catalog checker previously missed additional printf arguments, length modifiers, unsupported conversions, and plural branch type changes. Translated command fragments also escaped checks. Generic formatting followed the process locale, several native SwiftUI roots retained the system direction, and the App could store an already translated billing period in the Widget snapshot. Chinese script tags with regional suffixes were not recognized by the website.

The change validates complete format signatures and plural dictionaries, preserves executable command literals, propagates the selected resource locale and text direction, keeps shared period keys canonical, and normalizes website language tags. It also corrects the affected catalog values. This investigation establishes localization defects; it does not establish a remotely exploitable security vulnerability.

## Focused validation

- App: 23 catalogs and 2,294 English reference keys; Widget: 23 catalogs and 193 synchronized keys; website: 23 locales and 138 messages.
- Five Node format tests and three website language tests run in `make check`. Eight catalog corruption fixtures were rejected, including `%n`, additional pointer arguments, length changes, plural type changes, and translated npm options.
- Isolated runtime matrices passed 5,106 App resource cases, 2,944 concurrent lookups, and 4,439 Widget resource cases.
- Swift regressions cover Arabic digits, plural language selection, the real SwiftUI environment modifier, RTL drag direction, protected technical literals, and a Persian App sharing a canonical period with an English Widget.
- A real browser checked simplified and traditional Chinese script/region tags and Arabic direction.

## Full suite acceptance

All 1,569 selections across 143 original groups were covered. This is an aggregate result: after interrupted runs, only remaining groups were resumed. A slow cost group passed all twelve suites when split; the unchanged 50 ms menu-rendering budget passed independently. Full testing found and corrected a source-position fingerprint shift, an English date-reader assumption on a non-English host, and the chart hosting type regression introduced by the outer localization modifier. The final affected-suite run passed 93 tests in 11 suites; renderer and architecture recovery passed 131 tests in two suites. The last fifteen resumed groups all passed. The final `make check` returned 0 with no lint violations.

Original failures remain in the retained local logs. This evidence does not claim one uninterrupted clean `make test` invocation. Opt-in native proof tests retain their documented skips. See [validation summary](validation-summary.json).

## Native evidence

The screenshot uses the freshly built full App through its existing DEBUG isolation entry point. The displayed editor is the production shortcut editor in Arabic, with the production language/direction modifier. Settings and accounts use fixture stores, provider discovery is disabled, and Keychain access is disabled.

![Arabic shortcut editor](https://raw.githubusercontent.com/DGPisces/CodexBar/a8f154f2182608926d687b0c6fa7b43aa52029c6/.github/pr-proof/i18n-hardening/ar-shortcuts.png)

[Environment receipts](environment-receipts.json) record six languages and both the production modifier and explicit reference environments. [Notification receipt](notification-delivery.json) records a Chinese credential fixture returned by macOS's delivered-notification query on macOS 27.0.1. Temporary test-app notification permission was restored to its initial disabled state. The original local artifacts are retained; the published receipt replaces its absolute bundle path, and account, usage, token, and monetary data are withheld.

These native App proofs were recorded at `551e9dd0a`. Subsequent changes remove a comment that moved an architecture-check fingerprint, fix an English date-reading test assumption, and move the chart localization environment inside the concrete chart views to preserve menu hosting types. The screenshot and notification receipt do not verify those chart views; the existing hosted-menu refresh and chart suites verify their final behavior.

The twelve production Widget source files also compiled using the native `Bundle.main` resource branch. An isolated App Group was verified before attempting registration. The temporary extension was not registered by the system, so a fresh WidgetKit host display is **unverified**. This host has no Parallels macOS VM, which the repository requests for Widget/Tahoe UI proof. Previous Widget host evidence in the parent PR belongs to its original source revision.

## Acceptance boundary

The machine checks validate resource contracts and covered runtime behavior. They do not certify every translation's meaning or style. The 22 non-English catalogs still need native-speaker review. Maintainer approval and merging this supplement and the upstream PR remain separate steps.

## Indonesian countdown review follow-up

The [parent PR review](https://github.com/steipete/CodexBar/pull/4223#issuecomment-5965412527) identified three Indonesian countdown entries that render a day component with `j`, the hour abbreviation. These entries were missed in the initial supplement. They now use the explicit day word `hari`.

The regression invokes the production provider-detail formatter on both primary and secondary z.ai detail values. It covers day-only, day/hour, and day/minute values, plus three hour/minute controls. The pre-fix run reproduced six failed expectations in the three day-bearing cases. The post-fix `LocalizationSemanticContractTests` and `ZaiMenuCardTests` run passed 12 tests in two suites, and a fresh `make check` returned 0. See the [normalized follow-up receipt](countdown-review-followup.json).

The earlier 143-group full-suite acceptance belongs to the earlier source revision. This catalog-only follow-up and its new regression received focused verification and repository checks; the full suite was not rerun. The parent PR's head remains unchanged until its author integrates the supplement.
