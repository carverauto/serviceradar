# ServiceRadar Atlas proposal review evidence

This documents the reduced `add-topology-bitmap-query-index` design. It is
artifact validation, not proof that the implementation or rollout is complete.

## Artifacts

| Artifact | SHA-256 | Bytes |
| --- | --- | ---: |
| [Architecture source](topology-bitmap-index.architecture.json) | `dafe233cc5fdac61462a4dca39eb0624d9420cd49bc2d060872bbae26f9a317c` | 3688 |
| [Architecture HTML](topology-bitmap-index.html) | `64ca70e0515cbd6053f7d6504da030c94192ad94e26ab5086a87aab764ed3209` | 707942 |
| [Portable proposal](topology-bitmap-index-proposal.html) | `df89112962525adb55d5f63a508627a8f3a4f8afa8a70f41e76d72fffb7ed9d4` | 873980 |

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
| `proposal.md` | `14e99f7907617406b0c7e33e67cbb08ac1b324b90485b983c4250f475d9fda62` |
| `design.md` | `cec2f3c9522d0157721153b4a12383cc058185895bbf12962fc324f650a2d221` |
| `specs/topology-god-view/spec.md` | `1e772b2a7a43ef11a41724db7fb2fd5d97a20eb15371891be85b87556de53d17` |
| `tasks.md` | `42888f8c19ec4a83bfec18ff5115d79a26fe51e05856c9421ee3d3d9cfce551b` |
| `review-response.md` | `49039d99c899db798df55c02377496a882631a1aa70b826fa8cff29a805d3cdd` |

The current snapshot includes the final review corrections for bounded retries,
displayed membership receipts, deterministic telemetry admission, parser/native
limits, identity retention, catalog readers and schema-valid scale fixtures.
It explicitly qualifies the earlier 414-target unit result as predating these
fixes. Hosted database and combined scale acceptance remain unchecked.
The portable summary retains camera-only sharing, paged labels without search,
masked zero-match glyphs, hidden unproven aggregate links and disabled compression.
Its handoff source SHA-256 is
`1ab52c003af353188311316809eb957ce18d3dc7ac57d07169299d076669cc4f`.
Architecture source and delivered diagram bytes are unchanged.
The choices ledger and measurement report were reviewed as supporting evidence;
they are not presented as additional embedded source documents.

Colors and typography follow existing ServiceRadar styles. All viewer assets
are embedded; no external assets are required. This refresh reuses the portable
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

The portable proposal also loaded in Chrome in both themes at 1470 x 780 and
at a narrow width of 500 pixels. Its five embedded source sections and diagram
loaded. Document width matched viewport width; vertical scrolling is intentional.
This is an artifact spot check, not product performance acceptance.

The current source refresh repeated containment and theme checks in Chrome at
1470 x 780 and 500 x 780, in both light and dark themes. Each check required
matching document/viewport widths, all five source sections and checksums, and a
loaded embedded diagram. All four checks passed. This is a containment check;
the unchanged architecture diagram keeps its existing visual-review receipts.
No product or GPU acceptance is inferred from this documentation refresh.

Product GPU evidence is recorded separately in
[the synthetic hardware acceptance report](../topology-bitmap-gpu-acceptance.md).
Repository-wide testing and production-route acceptance belong to the integrated
implementation; no previous proposal-only test run is claimed for this refresh.
