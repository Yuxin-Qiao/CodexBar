# Historical localization proof

The contributor recorded packaged-app, delivered-notification, and installed-widget evidence before the maintainer integration. Those recordings and their source identities remain available at the immutable revision below; they are historical evidence, not captures of the final merged candidate.

[Original runtime proof, receipts, and images](https://github.com/DGPisces/CodexBar/tree/a8f154f2182608926d687b0c6fa7b43aa52029c6/.github/pr-proof)

The production `--localization-proof` entrypoint and its alternate settings startup mode have been removed. Normal settings initialization remains identical to current main. Dictionary-backed defaults and synthetic rendering stay in the test target.

Headless proof can be regenerated with `ShareStatsTests` and `WidgetAccentProofRenderTests`, using `CODEXBAR_SHARE_STATS_SCREENSHOT_DIR` and `CODEXBAR_WIDGET_PROOF_DIR` respectively. These tests use synthetic usage data and scoped localization overrides; they do not launch the app, access real accounts, or deliver notifications.
