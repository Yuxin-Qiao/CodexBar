# Provider browsing native previews

Feature revision: `4e256d2855c8b602309d199ab580949e903684cf`.

These are native SwiftUI previews from `ProviderBrowsingScreenshotTests`, using isolated in-memory settings and five explicitly enabled fixture providers. No real accounts, credentials, usage, or provider refreshes are involved. PNG metadata has been removed without changing image pixels.

- `sidebar-family-enabled-en-230.png`: company grouping with the enabled-only filter at a 230-point sidebar width.
- `sidebar-restored-en-230.png`: default-order restoration and the one-step Undo footer.

The previews demonstrate layout and grouping, not installed-app click/drag behavior, connection state, or selected-row colors. The native bitmap selection artifact also reproduces in the unchanged row reference.
