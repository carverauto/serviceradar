# Honesty Review — *Causal Anomaly Detection at the Edge*

Paper: `papers/deepcausality-anomaly-engine/` (main.tex + sections/00–11)
Reviewed at HEAD `2f349a3ea docs(paper): strengthen causal narrative, add CausalFlow listing (review pass)`.
Scope of this document: **assessment only.** No `.tex` prose was modified. The authors decide what (if anything) lands.

---

## 1. Verdict

The paper's **method and numbers are described honestly.** The algorithm is correctly stated as a bounded-window Welford mean/variance **z-score** with N-consecutive-sample confirmation, baseline-integrity admission, and counter rate-normalization; the throughput numbers (~480k–510k evals/s/core steady-state, kernel/cold figures separated) are properly caveated; and the limitations section is unusually candid ("Every number in this paper is throughput or memory. We have not measured precision or recall").

The problem is the **framing, not the facts.** The title "Causal Anomaly Detection at the Edge," the pdftitle, two of the three candidate titles, the §1 "Why a causal engine" lead with its "small unit of **causal inference**" claim, and the abstract/contributions "path to / on-ramp to **causal interventions**" all imply Pearl-style causal inference that the engine does not perform. Per verified ground truth, DeepCausality is used here as **plumbing only** (`CausalFlow::process` as a streaming pipeline combinator, `SlidingWindow`/`VectorStorage` as data structures) — the crate's own Cargo.toml says exactly this. There are no structural causal models, do-calculus, counterfactuals, or interventions anywhere, and the engine does not infer causes of anomalies. The HEAD commit literally set out to "strengthen causal narrative," which is the direction the paper should *not* lean. Notably, §9.2 already states the honest position ("We make no causal-inference claim about the metrics themselves") — the title and intro **contradict the paper's own related-work section.**

Bottom line: a defensible, useful systems paper (fast edge detector + CausalFlow as a high-throughput substrate + edge/core parity + honest about unmeasured accuracy) is wearing a causal-inference costume it doesn't need.

---

## 2. Overclaim Inventory

Legend:
- **[FIX]** — genuine overclaim that implies causal *inference*; should change.
- **[KEEP-IF-REFRAMED]** — legitimate DeepCausality substrate terminology (causaloid / CausalFlow / sliding window); fine *only* when framed as the implementation substrate, not as evidence the detection is causal.
- **[ANCHOR]** — already-honest line; preserve and build the reframe on top of it.

### main.tex

| Loc | Quoted text | Class | Honest replacement | Rationale |
|-----|-------------|-------|--------------------|-----------|
| `main.tex:94` | `\textbf{Causal Anomaly Detection at the Edge}` (the paper title) | **[FIX]** | e.g. *"A High-Throughput Edge Anomaly Detector in Rust, Hosted on DeepCausality's CausalFlow"* (see §3) | The detection is a z-score over a window; "Causal …Detection" asserts causal inference the engine never does. Biggest single overclaim. |
| `main.tex:95` | `\large A Real-Time, Per-Agent Anomaly Engine Built on DeepCausality` (subtitle) | **[ANCHOR]** | keep as-is | "Built on DeepCausality" is the correct substrate framing. This subtitle is the honest version of what the title should say. |
| `main.tex:70` | `pdftitle={Causal Anomaly Detection at the Edge}` | **[FIX]** | match the new honest title | Reader-visible PDF metadata; carries the same overclaim as the title. |
| `main.tex:16–17` | candidate title *"Computational Causality for Streaming Anomaly Detection: A High-Throughput Rust Engine"* | **[FIX]** | *"Streaming Anomaly Detection on DeepCausality's CausalFlow: A High-Throughput Rust Engine"* | "Computational Causality **for** … Detection" frames the causality as the detection mechanism; it is the hosting substrate, not the method. |
| `main.tex:18–19` | candidate title *"A Causaloid-Based Anomaly-Detection Engine: Designing for Millions of Evaluations per Second in Rust"* | **[KEEP-IF-REFRAMED]** | usable; consider *"… for High-Throughput Streaming Detection in Rust"* | "Causaloid-based" is substrate terminology and is acceptable. Caveat: "Millions of evaluations per second" overstates the **shipped** path (~480k–510k steady-state); "millions" only holds for the cold/short-window run (1.365M) and the bare kernel (116M). Don't headline a number the shipped detector doesn't sustain. |
| `main.tex:20` | candidate title *"Sliding-Window Causality at Speed: An $O(1)$ Streaming Anomaly Reasoner"* | **[FIX]** | drop; e.g. *"A Bounded-Window Streaming Anomaly Reasoner in Rust"* | Two defects: (a) "Sliding-Window **Causality**" implies causal inference; (b) "$O(1)$" is factually wrong for the shipped path, which the paper itself states is $O(W)$ recompute (§5.6, §8.3). The $O(1)$ reversible accumulator exists in-core but is *not* the shipped detector. |
| `main.tex:2` | header comment: *"A High-Throughput Anomaly-Detection Engine in Rust with Computational Causality"* | **[FIX]** (source comment, not rendered) | *"… in Rust, hosted on DeepCausality's CausalFlow"* | Non-rendered, so low priority, but it seeds the "with Computational Causality" framing throughout. |

### sections/00-abstract.tex

| Loc | Quoted text | Class | Honest replacement | Rationale |
|-----|-------------|-------|--------------------|-----------|
| `00-abstract.tex:1` | comment: *"Pure Rust causal anomaly engine on DeepCausality."* | **[FIX]** (source comment) | *"Pure Rust edge anomaly detector hosted on DeepCausality's CausalFlow."* | Non-rendered; corrects the working framing. |
| `00-abstract.tex:11–12` | *"built on \dc{}, a high-performance computational-causality framework."* | **[KEEP-IF-REFRAMED]** | keep, optionally add "…used here as the streaming substrate" | Describes the dependency accurately; fine as substrate. |
| `00-abstract.tex:12–13` | *"Each metric series is watched by a \emph{causaloid}, and the detector's control flow is written as a \dc{} \texttt{CausalFlow} pipeline."* | **[KEEP-IF-REFRAMED]** / **[ANCHOR]** | keep | Correct, concrete substrate description. This is the honest way to mention DeepCausality. |
| `00-abstract.tex:15–16` | *"…and leaves open a path to causal interventions."* | **[FIX]** | *"…and leaves room to add the guarded corrective-action step from DeepCausality's reference example."* | "Causal interventions" reads as do-calculus interventions. The real future step is the throttle action from the corrective-DDoS example — a *corrective action*, not a causal intervention. Drop the word "causal" here. |

The rest of the abstract (Welford, window z-score, N-consecutive confirmation, checkpointable window, OCSF findings, ~0.5M evals/s/core, explicit "what we have not yet measured, chiefly detection accuracy") is **honest** and should be preserved.

### sections/01-introduction.tex

| Loc | Quoted text | Class | Honest replacement | Rationale |
|-----|-------------|-------|--------------------|-----------|
| `01-introduction.tex:11–12` | *"…with a detector framed in the language of computational causality."* | **[KEEP-IF-REFRAMED]** | *"…with a detector expressed as a DeepCausality CausalFlow pipeline."* | "Language of computational causality" leans on the costume; naming the concrete substrate (CausalFlow) is both honest and more informative. |
| `01-introduction.tex:14` | `\paragraph{Why a causal engine.}` | **[FIX]** | *"Why express it on CausalFlow."* | The section heading asserts the engine is causal. It is a statistical detector hosted on a causal-framework's pipeline primitive. |
| `01-introduction.tex:15–16` | *"We model each series as a \emph{causaloid} from \dc, a small unit of \textbf{causal inference} evaluated against an explicit context…"* | **[FIX]** | *"…a small, composable unit of computation evaluated against an explicit context (here, the series' recent window)."* | This is the crux overclaim. A rolling z-score is **statistics**, not "causal inference." Keep "causaloid" (substrate); delete "causal inference." |
| `01-introduction.tex:17–18` | *"What the causal formulation buys us is the shape of the engine around it."* | **[KEEP-IF-REFRAMED]** | *"What the CausalFlow formulation buys us…"* | The engineering benefits (composability, statelessness, parity) are real and come from the pipeline structure, not from causality. Rename "causal" → "CausalFlow." |
| `01-introduction.tex:22–25` | *"…it also has a direct path to the framework's intervention step, which would let the same engine take guarded corrective action on the host…We do not take that step here…"* | **[KEEP-IF-REFRAMED]** | keep, but call it "the framework's corrective-action step" | This body text is *more* honest than the abstract: it ties "intervention" to a concrete guarded corrective action and explicitly says they don't do it. Reframe by avoiding the bare word "intervention," which a causal-paper reader will misread. |
| `01-introduction.tex:38` | *"A causaloid-based formulation of that detector on \dc{} (a \texttt{CausalFlow} pipeline …)"* | **[KEEP-IF-REFRAMED]** / **[ANCHOR]** | keep | Accurate substrate description of the contribution. |
| `01-introduction.tex:42` | *"…and an on-ramp to causal interventions."* | **[FIX]** | *"…and a hook for the corrective-action step used in DeepCausality's examples."* | Same defect as abstract:15–16. "Causal interventions" implies inference; the real thing is a corrective action. |

### sections/02-background.tex

| Loc | Quoted text | Class | Honest replacement | Rationale |
|-----|-------------|-------|--------------------|-----------|
| `02-background.tex:1` | `\section{Background: Computational Causality and \dc}` | **[KEEP-IF-REFRAMED]** | keep | Legitimate as background on the *framework*. Background may describe DeepCausality's own model; it just must not transfer that property to the z-score. |
| `02-background.tex:4–8` | *"\dc{} is the reference implementation of the Effect Propagation Process, a model of computational causality… the engine in this paper uses two parts of it: the Flow API … and the sliding-window data structure…"* | **[ANCHOR]** | keep | Honest: explicitly scopes usage to the Flow API (pipeline) and the sliding-window data structure — i.e., plumbing. Build the reframe on this. |
| `02-background.tex:11–12` | *"In \dc{}, a unit of inference is a \emph{causaloid}: a function that maps an incoming effect to an outgoing effect…"* | **[KEEP-IF-REFRAMED]** | keep (this is DeepCausality's own definition) | Describing the framework's vocabulary is fine. The slip is when "unit of inference" gets re-applied to *our z-score* (see intro:15). |
| `02-background.tex:18–22` | *"We do not need that machinery here. We need a small, deterministic, testable unit of inference that runs on every sample, and a causaloid over a recent window is exactly that."* | **[KEEP-IF-REFRAMED]** | replace "unit of inference" → "unit of computation/evaluation" | The disclaimer ("We do not need that machinery") is honest, but "unit of inference" still dresses statistics as inference. Small wording fix. |
| `02-background.tex:44–53` | corrective-DDoS reference pattern; *"Our detector borrows the first three ideas … and stops at emitting a verdict. We do not yet take the corrective action…"* | **[ANCHOR]** | keep | Exemplary honesty: states exactly what is and isn't borrowed. |

### sections/03-motivation.tex
No causal-inference overclaims. The task framing (per-series z-score, gauges vs counters, recall/precision two-tier) is honest. **No action.**

### sections/04-architecture.tex

| Loc | Quoted text | Class | Honest replacement | Rationale |
|-----|-------------|-------|--------------------|-----------|
| `04-architecture.tex:37` | `\subsection{The causal formulation}` | **[KEEP-IF-REFRAMED]** | *"The CausalFlow formulation"* | Rename to the substrate primitive; the subsection's body is about the pipeline, not causality. |
| `04-architecture.tex:38–44` | *"Each series is watched by a causaloid… \texttt{reason\_impl}, is a \texttt{CausalFlow} pipeline: it hydrates the detector state… The pass is stateless."* | **[ANCHOR]** | keep | Accurate, concrete substrate description. |
| `04-architecture.tex:46–48` | *"That same \texttt{branch\_with} is where a future guarded intervention would hook in…"* | **[KEEP-IF-REFRAMED]** | *"…a future guarded corrective action would hook in…"* | Concretely it's the branch where a corrective action could fire. Avoid bare "intervention." |
| `04-architecture.tex:65–66` | caption: *"Each step lowers to a causal-monad operation; the breach branch confirms or resets…"* | **[FIX]** | *"Each step is a \texttt{CausalFlow} combinator; the breach branch confirms or resets…"* | "Causal-monad" is rhetorical dressing — `CausalFlow::process` is a pipeline combinator, not a causal-semantics monad. Calling pipeline steps "causal-monad operations" overclaims causal structure. |

### sections/05-edge-detector.tex
Pure method description (Welford, z = |x−μ|/σ, τ=3, confirmation c=5, counter rate-normalization, O(W) recompute). **Honest throughout — [ANCHOR] for the whole section.** It even concedes the shipped path is $O(W)$ not $O(1)$ (lines 107–110), which directly refutes the `main.tex:20` candidate title. No action.

### sections/06-central-seasonal.tex
Seasonal residual-z over hour-of-week buckets, recall/precision split. Matches ground truth (central = seasonal residual-z). No causal-inference overclaim. **No action.**

### sections/07-implementation.tex

| Loc | Quoted text | Class | Honest replacement | Rationale |
|-----|-------------|-------|--------------------|-----------|
| `07-implementation.tex:8–10` | *"Its only substantial dependencies are two \dc{} crates, \texttt{deep\_causality\_core} and \texttt{deep\_causality\_data\_structures}…"* | **[ANCHOR]** | keep | Honest about *which* parts of DeepCausality are used — exactly the "plumbing" crates. Matches ground truth. |

Rest of section (gRPC sidecar, OCSF class 2004/200401, checkpoint, 256 MiB / 0.5-core cgroup budget, parity test) is honest. No action.

### sections/08-evaluation.tex
Strong honesty: separates kernel/recompute/shipped throughput, flags macOS RSS over-report, `\NEEDCITE` to re-measure on Linux, and the threats-to-validity dossier lists "no detection-accuracy (precision/recall) evaluation; synthetic workload; single machine, single run." **[ANCHOR] for the section.** One non-causal caution: avoid letting the kernel's 116M or the cold 1.365M figures be quoted as the engine's rate (the body already pins the steady-state ~480k, which is correct). No action needed.

### sections/09-related-work.tex

| Loc | Quoted text | Class | Honest replacement | Rationale |
|-----|-------------|-------|--------------------|-----------|
| `09-related-work.tex:14–16` | *"The contribution is not a new detector but where it runs and how cheaply: a per-series $z$-score with confirmation, expressed as a causaloid, light enough to run on every agent."* | **[ANCHOR]** | keep | This is the true contribution statement. Use it to anchor the retitle. |
| `09-related-work.tex:20–29` | *"We use the computational-causality framing for its engineering properties… We make no causal-inference claim about the metrics themselves."* | **[ANCHOR]** | keep verbatim | The decisive honest line. **The title and §1 should be brought into line with this, not the reverse.** |

### sections/10-discussion.tex

| Loc | Quoted text | Class | Honest replacement | Rationale |
|-----|-------------|-------|--------------------|-----------|
| `10-discussion.tex:20–33` | Limitations: *"The honest gap is accuracy. Every number in this paper is throughput or memory. We have not measured precision or recall…"* | **[ANCHOR]** | keep | Model limitations paragraph; preserve. |
| `10-discussion.tex:32–33` | *"…the corrective step that \dc{}'s example takes is deliberately left off."* | **[ANCHOR]** | keep | Honest. |
| `10-discussion.tex:41–44` | *"The intervention step that \dc{}'s own corrective examples use would let the detector take a guarded action… and because causaloids compose, the same per-series verdicts can feed larger causal models later."* | **[KEEP-IF-REFRAMED]** | *"…the corrective-action step … and the per-series verdicts could later feed larger models."* | Already hedged as future work. Reframe: say "corrective-action step" not "intervention step"; soften "larger causal models" so it doesn't promise causal modeling as a natural, near extension. |

### sections/11-conclusion.tex
*"a per-series detector built on \dc{} that runs on each monitoring agent… expresses detection as a \texttt{CausalFlow} pipeline… scores each sample with a $z$-score… a single core sustains roughly half a million evaluations per second… The open question is detection accuracy, which we have not yet measured."* — **[ANCHOR].** The conclusion is honest and on-message; it does not call the method "causal." Build the abstract/title to match this. No action.

---

## 3. Proposed Title

**Recommended:**
> **A High-Throughput Edge Anomaly Detector in Rust, Hosted on DeepCausality's CausalFlow**
> *Subtitle (keep existing):* A Real-Time, Per-Agent Anomaly Engine Built on DeepCausality

**Alternates** (both honest; #2 reuses the existing candidate's substrate term):
1. *Real-Time Per-Agent Anomaly Detection on DeepCausality: A Bounded-Window z-Score Engine in Rust*
2. *A Causaloid-Based Streaming Anomaly Detector: High-Throughput Edge Detection in Rust*

Each leads with **detector** (the statistical method) + **edge/real-time** (the deployment contribution) + **DeepCausality/CausalFlow as host/substrate** (the co-author's showcase value), and none asserts causal inference. Avoid the existing `main.tex:20` `$O(1)$` candidate entirely: the shipped path is $O(W)$.

---

## 4. Proposed Abstract (honest rewrite of `sections/00-abstract.tex`)

*Drop-in replacement candidate — leads with the detector and the substrate, keeps the real method, the ~500k evals/s, the OCSF output, and the unmeasured-accuracy admission; removes the "causal inference / causal interventions" implications.*

> ServiceRadar runs system and network monitoring across a fleet of agents, and those agents emit millions of metric time series. Catching anomalous metrics across the fleet, in real time, is the problem this paper addresses. We present an anomaly **detector** that runs at the edge, on each agent. The detector is a per-series statistical test: it keeps only a bounded window of recent samples, computes the running mean and variance with Welford's method over that window, and raises a verdict when a sample's $z$-score stays past a threshold for several consecutive samples. A breaching sample is withheld from the baseline so a sustained anomaly cannot raise its own normal. We host the detector on DeepCausality, a high-performance computational-causality framework, **used here as a streaming substrate**: each series is a *causaloid* and the per-sample control flow is a DeepCausality `CausalFlow` pipeline. Expressing the detector this way keeps each series small and composable, lets the same core produce identical verdicts on the agent and in the central tier, and keeps per-series state to just the window, so a series is cheap to checkpoint and restart. Verdicts are emitted as Open Cybersecurity Schema Framework findings. The engine is written entirely in Rust and runs as a resource-capped add-on alongside each monitoring agent. On a single core it sustains roughly half a million sample evaluations per second, far more than an agent produces, so it fits inside a small CPU and memory budget and flags anomalies as the data is produced rather than shipping every raw point to a central service. We describe the engine's design, its detection algorithm, and microbenchmarks of the reasoner. We make no causal-inference claim about the metrics: the method is robust statistics, and DeepCausality is the substrate that hosts it. We are explicit about what we have not yet measured, chiefly detection accuracy on labeled data.

Key edits vs. the current abstract: removed *"path to causal interventions"* (`:15–16`); added the explicit "used here as a streaming substrate" qualifier; added a one-line "we make no causal-inference claim … robust statistics" to mirror the honest §9.2 line; everything else (method, ~0.5M evals/s, OCSF, unmeasured accuracy) preserved.

---

## 5. What the Paper Can Honestly Claim

- **A fast, real-time edge anomaly *detector*** — bounded-window Welford z-score with N-consecutive-sample confirmation and baseline-integrity admission — that sustains **~480k–510k evaluations/s/core steady-state** on commodity hardware (Apple M4), inside a small CPU/memory budget (256 MiB / 0.5-core cgroup).
- **A deployment model**: per-series detection cheap enough to run on *every* agent, so the central tier no longer pays for detection or grows that cost with the fleet.
- **DeepCausality's `CausalFlow` (+ `SlidingWindow`) as a high-throughput streaming substrate** that hosts the detector — composable per-series "causaloids," legible pipeline control flow — which is the genuine showcase value for the DeepCausality co-author, *as plumbing, not as inference.*
- **Edge/core verdict parity by construction**: one shared Rust `anomaly-core` computes identical verdicts wherever it runs, pinned by a parity test; correct gauge vs. rate-normalized-counter handling (resets, wraps, gaps).
- **Standard, joinable output**: OCSF Detection Findings (class 2004 / type 200401) on a provisional edge key re-keyed to the canonical series key on ingest, so edge and central seasonal verdicts join.
- **Honesty about scope**: numbers are throughput and memory only; **detection accuracy (precision/recall) is explicitly not yet measured** (no labeled data), the workload is synthetic, single-machine/single-run, and macOS over-reports RSS vs. the Linux target.

What the paper should **not** claim: that it performs causal inference, causal discovery, counterfactual or do-calculus interventions, or that the z-score is a "unit of causal inference." It does not infer causes of anomalies. (§9.2 already says this — the front matter should be brought into line with it.)
