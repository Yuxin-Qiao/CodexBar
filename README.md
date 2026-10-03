# Persistent CLI source selection: real-configuration validation

Production revision: `e916f6930eab207cae8194118577940c6df6610d`, for [PR #4197](https://github.com/steipete/CodexBar/pull/4197).

The freshly built CLI ran on this Mac using a byte-identical copy of its existing, persisted CodexBar configuration. The input was not generated from a test fixture, rewritten, or anonymized before execution. The complete original and raw command outputs are retained privately. The live configuration was left unchanged; the supported `CODEXBAR_CONFIG` override selected the isolated copy. Each command ran in a separate process with a contained home and Keychain access disabled.

## Observed behavior

- Set Claude's source to `cli`; the setter exited successfully, the saved file contained the override, and a subsequent real `config dump` process loaded it.
- The selected provider's enablement and every other normalized configuration field remained unchanged.
- Unsupported provider/source combination, unknown source, and unknown provider each returned exit 1 and preserved the configuration file byte-for-byte.
- Set source to `auto`; the setter exited successfully and removed the persisted override. A subsequent `config dump` process observed the reset, with all other normalized fields retained.
- The original live configuration remained byte-identical throughout validation.

The field comparisons use the configuration loaded through the existing normalizer, which supplies missing provider defaults. They do not claim that the successful writes preserve JSON whitespace or bypass normal configuration normalization. Invalid inputs preserve the actual file bytes.

## Public derivative

[transcript-anonymized.txt](transcript-anonymized.txt) contains actual setter stdout and exit codes, with only `configPath` replaced by `<isolated-config>`. JSON whitespace is normalized when producing this post-validation derivative. `config dump` outputs are not published because they include private account metadata even with credential redaction. [receipt.json](receipt.json) contains Boolean assertions for persistence, separate-process reload, preservation, invalid writes, reset, and provenance.

No credential values, personal paths, account metadata, config contents, or private source hashes are published. This validates the local persistence interface, not a provider fetch: no usage API, browser-cookie import, or credential probe was invoked. It is real-configuration evidence executed against an isolated copy, not a claim that the user's active app configuration was changed.

Maintainer approval of the proposed persistent-source CLI interface remains outstanding; this evidence does not supply that approval.
