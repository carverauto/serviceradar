# causal-online-correction Specification (delta for add-causal-mitigation)

This delta adds the online detect→mitigate control loop that turns the engine from a batch
classifier into a closed-loop responder, carrying the anti-poisoning discipline the
`corrective_ddos_detector` template teaches. It runs on the `add-causal-engine` chassis in the
generic reasoning crate (`rust/causal-reasoning`) and hands latch decisions to the authority
layer (`causal-mitigation-authority`).

## ADDED Requirements

### Requirement: Online Detect-Mitigate Correction Loop

The engine SHALL run an online correction tick loop built from `CausalFlow::iterate_n` with a
per-tick `bind` (ingest one sample, update a `SlidingWindow` z-score) and `branch_with`
(`alternate_value`) latch, and this loop SHALL enforce three disciplines: (a)
**baseline-withholding** — an anomalous sample SHALL NOT be pushed into the baseline window
(`if !anomalous { window.push(sample) }`), so the detector cannot be trained to accept a
slow-ramp flood (anti-poisoning / "boil-the-frog"); (b) **consecutive-slots debounce** —
mitigation SHALL latch only after the number of consecutive anomalous slots reaches a
configured `trigger_slots` threshold, so a single noisy spike does not trigger a response; and
(c) **latch-once mitigation with operator-gated release** — mitigation SHALL latch at most once
per active episode, and stand-down SHALL be confirmed against the **raw** offered load (not the
withheld baseline) and SHALL require operator gating before release.

#### Scenario: A slow-ramp flood keeps reading anomalous instead of inflating its own baseline

- **GIVEN** a slowly ramping offered load whose samples are classified anomalous
- **WHEN** the correction loop processes each tick
- **THEN** each anomalous sample SHALL be withheld from the baseline window
- **AND** the baseline SHALL NOT rise to absorb the ramp
- **AND** subsequent ramp samples SHALL continue to read as anomalous rather than being re-baselined as normal

#### Scenario: A single spike does not trigger mitigation

- **GIVEN** a single anomalous slot followed by normal slots, with `trigger_slots > 1`
- **WHEN** the correction loop evaluates the debounce condition
- **THEN** mitigation SHALL NOT latch
- **AND** the loop SHALL continue without a response

#### Scenario: Mitigation latches once and releases only on raw-load abatement with operator gating

- **GIVEN** consecutive anomalous slots that reach `trigger_slots` and cause mitigation to latch
- **WHEN** further anomalous ticks arrive while mitigation is latched
- **THEN** mitigation SHALL NOT latch a second time for the same episode
- **AND** release SHALL occur only after abatement is confirmed on the raw offered load AND an operator gate confirms stand-down
