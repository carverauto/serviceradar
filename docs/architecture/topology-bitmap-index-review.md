# ServiceRadar Atlas proposal review evidence

This documents the reduced `add-topology-bitmap-query-index` design. It is
artifact validation, not proof that the implementation or rollout is complete.

## Artifacts

| Artifact | SHA-256 | Bytes |
| --- | --- | ---: |
| [Architecture source](topology-bitmap-index.architecture.json) | `dafe233cc5fdac61462a4dca39eb0624d9420cd49bc2d060872bbae26f9a317c` | 3688 |
| [Architecture HTML](topology-bitmap-index.html) | `64ca70e0515cbd6053f7d6504da030c94192ad94e26ab5086a87aab764ed3209` | 707942 |
| [Portable proposal](topology-bitmap-index-proposal.html) | `ed1dabfebb04975c62c0b1ea6ea948c8947f5f5b58a974c5cf657918d5244376` | 864899 |

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

Proposal, design and requirements were checked at `8e92cbfd7a` and their
embedded checksums still match those files. Tasks and the review response
changed after that commit. The review response records corrected native memory
accounting and limits, the final deadline/mapping checks, the full remote unit
result (414 targets, two Swift platform skips), the completed negotiated
transport measurement, separate website delivery, and the remaining hosted
database and combined scale gates. Its source SHA-256 is
`4d8fa9b81f9265689e281b49778c073d09959c0abc445dfd9c4cacd6ec7abac4`.
The embedded tasks checklist records the negotiated compression result and
leaves task 4.2 and hosted database acceptance unchecked. That source SHA-256 is
`42888f8c19ec4a83bfec18ff5115d79a26fe51e05856c9421ee3d3d9cfce551b`.

The portable summary states current public limitations from the same handoff:
camera-only share links, paged labels without search, masked zero-match glyphs,
hidden unproven partial-aggregate links and disabled compression. The handoff
source SHA-256 is
`f23337edf4cf51396624347dc445df5787df10cc47903903c0818c3bd8287cfc`.
The portable summary and embedded review response were refreshed in place.
Prior architecture visual receipts were not rerun.
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

The final portable-only refresh repeated those four browser containment/theme
checks and verified the added acceptance/limitation prose. The architecture
source, delivered diagram and its existing visual receipts are unchanged. No
product or GPU tests were rerun for this documentation-only refresh. The later
summary and review-response text refresh updated the portable file in place and
was not repeated in the browser. The architecture receipt still identifies
`topology-bitmap-index.html`.

Product GPU evidence is recorded separately in
[the synthetic hardware acceptance report](../topology-bitmap-gpu-acceptance.md).
Repository-wide testing and production-route acceptance belong to the integrated
implementation; no previous proposal-only test run is claimed for this refresh.
