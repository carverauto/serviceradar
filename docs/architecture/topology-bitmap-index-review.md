# Topology bitmap proposal review evidence

This is documentation validation for
`add-topology-bitmap-query-index`, not implementation or performance acceptance.

## Artifacts

| Artifact | SHA-256 | Bytes |
| --- | --- | ---: |
| [Architecture source](topology-bitmap-index.architecture.json) | `aa7094f022eb464b0d39338759f72138e69d0ed2ab4b59239033ee1ae531d6fe` | 2557 |
| [Architecture HTML](topology-bitmap-index.html) | `432b1e89cbe513cf1d17a95e506523b991e630951098ee1210eb9529eacb3843` | 707820 |
| [Portable proposal](topology-bitmap-index-proposal.html) | `dbba9d9f92df76e833dc49446385e3db436a3de52b224bf57d242124966ada1a` | 796492 |

The portable proposal embeds the complete proposal, design, delta requirements,
unchecked implementation tasks and the architecture viewer. Each source document
has an embedded checksum. Its colors and typography follow ServiceRadar's
existing `elixir/web-ng/assets/css/app.css` tokens. No external assets are needed
to read the review. Lavish export reported zero unresolved local assets.

## Deterministic validation

- `openspec validate add-topology-bitmap-query-index --strict`: passed.
- Archify `validate` and `deliver`, architecture/showcase: 9/9 artifact checks,
  zero composition errors and zero warnings.
- One focused correction round moved two relationship labels out of node boxes.
- The delivered HTML is bound to the exact source bytes above.

## Browser evidence

Archify `visual-check` passed against the delivered HTML. Its
[machine receipt](topology-bitmap-index.visual-check.json) and
[light/dark contact sheet](topology-bitmap-index.visual-check.html) are retained.

| Desktop viewport | Document scroll width/height | Result |
| --- | --- | --- |
| 1440 x 900 | 1440 x 900 | No overflow |
| 1600 x 1000 | 1600 x 1000 | No overflow |
| 1920 x 1080 | 1920 x 1080 | No overflow |
| 2048 x 1320 | 2048 x 1320 | No overflow |

Perceptual review is separate: an image-capable review inspected all four
light/dark endpoint screenshots. Nodes, relationship labels, corridors and
cards were readable, with no crossings or clipping. `visual_review: passed`.
The machine receipt deliberately keeps its own `visualReview: pending` field;
automated checks do not perform perceptual review.

The portable proposal was additionally opened directly in Chrome. Its theme
toggle, full source sections and embedded architecture loaded with no console
messages. Inspected light/dark screenshots at 1440 x 1000 and a narrow viewport
whose measured width was 500 pixels; document width matched viewport width.
The long proposal intentionally scrolls vertically. This spot check does not
claim product GPU performance or exhaustive viewer interaction coverage.

## Repository checks

`make test` used `-c opt --config=remote` and completed with 413 passed and two
platform-specific skips (`ios_compile_test` and `swift_regression_test`).
[BuildBuddy invocation](https://carverauto.buildbuddy.io/invocation/a4b76c83-cae1-4216-bb23-e1b5b4e012dc).
No tests or production code changed in this proposal. Feature benchmarks and
database/browser behavioral acceptance remain unchecked implementation tasks.
