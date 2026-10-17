# ServiceRadar Atlas proposal review evidence

This documents the reduced `add-topology-bitmap-query-index` design. It is
artifact validation, not proof that the implementation or rollout is complete.

## Artifacts

| Artifact | SHA-256 | Bytes |
| --- | --- | ---: |
| [Architecture source](topology-bitmap-index.architecture.json) | `dafe233cc5fdac61462a4dca39eb0624d9420cd49bc2d060872bbae26f9a317c` | 3688 |
| [Architecture HTML](topology-bitmap-index.html) | `64ca70e0515cbd6053f7d6504da030c94192ad94e26ab5086a87aab764ed3209` | 707942 |
| [Portable proposal](topology-bitmap-index-proposal.html) | `e392229bfbce98b0135bd672ea2d0c37bd373cd6e3319e3b8dda92c2022860ff` | 903241 |

The portable proposal embeds checksummed copies of the approved proposal,
design, delta requirements, implementation tasks and review response. It also
embeds the architecture viewer. This snapshot explains server-side Roaring,
current-membership query pages, admitted-row SRMO replacements and binary SRTO
health/flow. It removes the discarded browser Roaring/WASM, XOR/chunks, outbox,
interface dictionary, owner routing and result cache designs. Source documents
remain authoritative as implementation proceeds.

The Atlas naming refresh includes the approved visible filter builder, literal
tag prefixes, current device/interface IP CIDR matching, named Prefix Tags and
the third review response. The source snapshot retains explicit unfinished
acceptance tasks and the deferred Arrow telemetry follow-up. Negotiated
WebSocket measurement is complete and compression stays disabled. Code
identifiers and protocol names remain unchanged.

All five embedded source documents were regenerated from the current files.
Their exact source checksums are:

| Source | SHA-256 |
| --- | --- |
| `proposal.md` | `35408df2d8f7b72f926b87ced8c293ee8035ab8d8a5c220d18325c68f2c04ecc` |
| `design.md` | `756cbb1d091c5d0f9710bcc322f4d6c1d323be97e23272f8207ac1d075078b9d` |
| `specs/topology-god-view/spec.md` | `41aa839c04a9c5aa921747092bcac25b55e3a3d459d0ffcc59760fdc005707a1` |
| `tasks.md` | `fd86e2bca9ef259849c2ed19b220b5c1358a5674b61d229a878465e666dc3482` |
| `review-response.md` | `55512dc38d8ee3446e8c580677e92c643d30d6126ec1fb255a0f7ff047f75ad4` |

The current snapshot includes the final review corrections for bounded retries,
displayed membership receipts, deterministic telemetry admission, parser/native
limits, identity retention, catalog readers and schema-valid scale fixtures.
The integrated remote unit gate passed 419 targets with two platform
skips at pre-rebase checkpoint `18ff6bd6d0`, invocation
`afe6cf35-2ec3-4d95-bbed-bee09930704f`. That commit is not an ancestor of this
branch, and the run was not repeated on this tree. Do not treat `77eaecceb6`
as that same gate. Hosted database and combined scale
acceptance remain unchecked; the unit tier excludes those database cases.
The portable summary retains camera-only sharing, paged labels without search,
masked zero-match glyphs, hidden unproven aggregate links and disabled compression.
Its handoff source SHA-256 is
`7cf149d2cd56557f0d0a9148741a3470bf18ef1f870f400849f3bb895ed28288`.
Architecture source and delivered diagram bytes are unchanged since the prior
artifact refresh on this feature branch; both differ from the PR base.
The choices ledger and measurement report were reviewed as supporting evidence;
they are not presented as additional embedded source documents.

Colors and typography follow existing ServiceRadar styles. All viewer assets
needed for operation are embedded; an optional JetBrains Mono web font loads
from Google Fonts and falls back to system monospace offline. This refresh reuses the portable
artifact shell and does not use a Lavish export.

## Validation

Archify `validate` and `deliver` passed 9/9 architecture/showcase checks with
zero composition errors and warnings. The delivered architecture HTML binds the
architecture source bytes listed above. This refresh required no visual
correction rounds.

Archify `visual-check` passed against that HTML at 1440 x 900, 1600 x 1000,
1920 x 1080 and 2048 x 1320. Each document matched its viewport without overflow.
The [machine receipt](topology-bitmap-index.visual-check.json) and
[light/dark contact sheet](topology-bitmap-index.visual-check.html) are retained.

Perceptual review separately inspected all four light/dark endpoint screenshots:
node names, relationship labels and cards were readable without overlap or
clipping. `visual_review: passed`. Automated checks retain their own separate
visual-review field.

An earlier portable proposal loaded in Chrome in both themes at 1470 x 780 and
at a narrow width of 500 pixels. Its five embedded source sections and diagram
loaded, and document width matched viewport width. That spot check is historical.
It does not cover the current embedded bytes.

The previous source refresh repeated containment and theme checks in Chrome at
1470 x 780 and 500 x 780, in both light and dark themes. Each check required
matching document/viewport widths, all five source sections and checksums, and a
loaded embedded diagram. All four checks passed. This is a containment check;
the unchanged architecture diagram keeps its existing visual-review receipts.
The current text refresh regenerated all five sections and checksums. Static
checks confirm five matching source hashes and byte-identical embedded diagram
content. Its new visual containment check was not run because browser policy
refused local file URLs; no alternate route was attempted. No product or GPU
acceptance is inferred from this documentation refresh.

Product GPU evidence is recorded separately in
[the synthetic hardware acceptance report](../topology-bitmap-gpu-acceptance.md).
Repository-wide testing and production-route acceptance belong to the integrated
implementation; no previous proposal-only test run is claimed for this refresh.
