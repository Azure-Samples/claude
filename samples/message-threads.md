# Message Threads

[Message Threads](https://platform.claude.com/docs/en/build-with-claude/message-threads) adds server-side conversation state to the Messages API. It requires `anthropic-beta: message-threads-2026-08-12`. These examples opt in separately; the existing quickstarts stay unchanged.

Each example asks Claude to remember `ORCHID-47`, then recall it on a second turn using only the new message.

| Language | Example / run instructions |
|---|---|
| Python | [`python src/message_threads.py`](../src/message_threads.py), from the repository root |
| TypeScript | [Run](typescript/README.md#message-threads) |
| C# | [Run](dotnet/README.md#message-threads) |
| Go | [Run](go/README.md#message-threads) |
| Java | [Run](java/README.md#message-threads) |
| PHP | [Run](php/README.md#message-threads) |
| Ruby | [Run](ruby/README.md#message-threads) |

Use the same [endpoint, model and authentication configuration](README.md#configuration) as the other samples. Pass the Foundry **deployment name**, not a different native model ID.

## SDK checks

All seven use native SDK thread helpers, not a custom replay implementation. The helpers add the beta header and keep the transcript in memory. Persist it yourself if it must survive a process restart.

| Language | Tested SDK | Notes |
|---|---|---|
| Python | `anthropic` 2.4.0 | Raised the floor from 2.1, which has no thread helper |
| TypeScript | `@anthropic-ai/sdk` 1.4.0 | Updated the tested pin from 1.1; see audit note below |
| C# | `Anthropic` 13.3.0 | Existing version works |
| Go | `anthropic-sdk-go/v2` 2.4.0 | Existing version works |
| Java | `anthropic-java` 3.3.0 | Works; live run emitted the existing missing-SLF4J-binding warning |
| PHP | `anthropic-ai/sdk` 1.3.0 | Works; Windows needed a trusted CA bundle for TLS |
| Ruby | `anthropic` 2.3.0 | Existing version works |

Each example passed offline wire tests and a live two-turn Foundry recall. PHP/Ruby used their local Azure CLI fallback; the other five used Azure Developer CLI credentials. Python 2.6 was unavailable in the configured package feed; 2.4 was installed and tested.

`npm ci` reported `2 high severity vulnerabilities`. Details could not be retrieved: the configured feed returned no usable audit report, and the public registry failed TLS negotiation. They remain unclassified; no forced dependency update was applied.

## Contract

- Create: send the conversation, `system` and `tools`, with `thread: {"type":"create"}`.
- Continue: send only new messages, with `thread: {"type":"continue","previous_message_id":"<last response id>"}`. Omit `system` and `tools`, including null values.
- Keep the model, beta headers and other [fixed fields](https://platform.claude.com/docs/en/build-with-claude/message-threads#what-to-send-on-each-request) unchanged. Each response ID can be continued once.
- Keep your own transcript. Threads are best-effort and expire after five idle minutes. On `404` with `error.details.error_code = thread_not_found`, replay the full conversation in a new create request. Do not treat every 404 as an expired thread.
- For streaming, wait for `message_stop` before continuing.

Threads are **not ZDR eligible**. The documented deletion window is at most one hour after last use; there is no list, get or delete API. Threads do not enable prompt caching or reduce token pricing by themselves.

## Foundry API checks

Tested on **2026-11-10**, against existing **Opus 5.5 and Sonnet 5.5** deployments in `eastus2`, with Microsoft Entra ID. No infrastructure changes were needed.

| Check | Observed |
|---|---|
| Create, delta-only continue, third-turn recall | Passed |
| Streaming create followed by continue | Passed |
| Tool call followed by a delta-only tool result | Passed; stored tools were retained |
| Missing beta header | `400`: `thread: Extra inputs are not permitted` |
| Missing / expired previous ID | `404`, `thread_not_found`; idle expiry checked after more than five minutes |
| Reusing an already-continued ID | `400`, `thread_already_continued` |
| Sending `system` / `tools` on continue | Rejected with `400`, including explicit nulls |
| Changing cache TTL or output effort | `400`, `thread_fingerprint_mismatch`; the unchanged retry still worked |
| Full-conversation replay after `thread_not_found` | Passed; the Python helper also recovered after 310 seconds idle |
| Token counting with `thread` | Rejected with `400`, as documented |

The basic flow also passed with both `anthropic-version: 2026-10-21` and `2023-06-01`.

**One contract discrepancy:** adding or removing top-level `cache_control` on continue returned `200` on both models. The guide marks that field as fixed and says a changed value returns `400`. Changing its TTL from `5m` to `1h` did return the documented fingerprint error. Keep it unchanged regardless.

This compares Foundry observations with Anthropic's documented contract, **not** a live native-endpoint comparison: no Anthropic account key was available. The cache-control discrepancy is not proven to be Foundry-specific. Other regions, managed identity, the one-hour deletion bound and unsupported organization settings were not tested.
