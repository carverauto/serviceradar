# Paper: A High-Throughput Anomaly-Detection Engine in Rust with Computational Causality

LaTeX source for a technical report on ServiceRadar's **causal anomaly-detection
engine**: the Rust engine (`rust/anomaly-core` + `rust/anomaly-addon`) built on the
[DeepCausality](https://www.deepcausality.com/overview/) framework.

## Scope

The paper is about the Rust anomaly engine and nothing else. It covers the
DeepCausality-based reasoner, the detection algorithm (an `O(1)` Welford z-score
driven by a `CausalFlow` pipeline), the reasoner's evaluation throughput
(evals/s per core), and the per-series engine that wraps it. "Causal" here means
computational causality: a causaloid reasoning over an evolving context.

The engine is described on its own terms. Host-runtime integration and the wider
telemetry pipeline are deliberately left out so the focus stays on the engine and
its algorithm.

## Build

Requires MacTeX / TeX Live (`pdflatex` + `bibtex` via `latexmk`).

```bash
./build.sh        # or: make
make view         # build + open the PDF (macOS)
make clean        # remove build artifacts
```

`build.sh` prepends `/Library/TeX/texbin` to `PATH`, so it works from a
non-interactive shell.

## Layout

```
main.tex              # document + preamble (single-column article, natbib)
sections/             # one file per section (\input from main.tex)
references.bib        # bibliography (BibTeX; abbrvnat style)
figures/              # image figures, if any (diagrams are inline TikZ)
```

## Drafting conventions

- `\TODO{...}`, `\NEEDCITE{...}`, and `\dossier{...}` markers render in color
  while `\drafttrue` (set in `main.tex`). Flip to `\draftfalse` before submission.
- Every quantitative claim traces to a benchmark or a cited source.

## Status

Full working draft: all sections written, four TikZ figures, two benchmark tables,
citations resolved. The prose is grounded in the engine source (`rust/anomaly-core`,
`rust/anomaly-addon`), the DeepCausality source, and the anomaly OpenSpec proposals.
Reasoner numbers come from `rust/anomaly-core/examples/reasoner_bench.rs`; the edge
sweep from `rust/anomaly-addon/examples/edge_bench.rs`. Open items are marked with
`\TODO` / `\NEEDCITE` (chiefly a Linux re-measure of memory, and a detection-accuracy
study).
