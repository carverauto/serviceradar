# Configuration Validation Semantics

> Normative specification for the predicate vocabulary and the rule engine. Three
> implementations (Rust, Go, Elixir) must agree with this document and with each other; the
> conformance vectors in `config/vectors/` are generated from it.

`config/proto/rules.proto` carries the shapes. This document carries the meaning. Where they
appear to disagree, this document governs.

## 1. Why the engine is specified before the predicates

`non_empty` is trivial, and three languages will agree on it by accident. Divergence lives in
**composition** — what happens when several rules touch one field, in what order violations are
reported, and what a rule does when it cannot apply. Those are genuine specification questions with
defensible answers either way, so they are answered here once rather than three times by accident.

## 2. The verdict type

Every predicate is a **pure, total function**:

```
evaluate : (value : Option<Value>, params : Params) -> Verdict

Verdict = Satisfied
        | Violated
        | NotApplicable
```

- **Total.** Defined for every input, including absence and, in principle, a value of the wrong
  type. A predicate never panics, raises, or returns an implementation-specific result.
- **Pure.** No I/O, no clock, no environment, no ambient state. The same inputs give the same
  verdict on every platform and every run.
- `NotApplicable` is distinct from `Satisfied`: it means the rule had nothing to judge, and it never
  produces a violation.

**Type mismatch is not a runtime concern.** A rule naming a numeric predicate on a string field is a
defect in the *rule set*, caught by the rule-set lint (§7), not a verdict. Instance type errors are
caught earlier still, by `protoc` when the committed `.textproto` is compiled.

## 3. Predicate definitions

Let `v` be the field value and `⊥` denote absence.

| Predicate | `v = ⊥` | `v` present |
|---|---|---|
| `Required` | **Violated** | Satisfied |
| `NonEmpty` | NotApplicable | Satisfied iff `len(v) > 0` |
| `IntRange(min,max)` | NotApplicable | Satisfied iff `min ≤ v ≤ max` (both inclusive) |
| `OneOf(S)` | NotApplicable | Satisfied iff `v ∈ S` |
| `Matches(p)` | NotApplicable | Satisfied iff `p` matches `v` (RE2, unanchored unless the pattern anchors) |
| `ForbiddenValue(x)` | NotApplicable | Satisfied iff `v ≠ x` |
| `RequiredIf(o,x)` | Violated iff `o` is present and `o = x`; else NotApplicable | Satisfied |
| `ForbiddenIf(o,S)` | NotApplicable | Violated iff `o` is present and `o ∈ S`; else Satisfied |
| `EqualAcrossEnvs` | see §6 | see §6 |

**`Required` is the only predicate that treats absence as a violation.** Everything else returns
`NotApplicable`. This single choice is what makes error output stable — see §4.

Bounds are **inclusive at both ends**. This is stated because it is the most likely point of
accidental divergence between three implementations, and the conformance vectors pin both edges.

`ForbiddenIf` takes a **set** where `RequiredIf` takes a single value. That asymmetry is
deliberate: the forbidding side enumerates the complement of what is permitted, so a per-value
rule would let a newly added enum value become permitted by omission. The meta-rule requires a
`RequiredIf`/`ForbiddenIf` pair keyed on the same enum to cover every value of it.

`Matches` uses **RE2**, available in all three ecosystems, with no backtracking and therefore no
pathological-input class. Patterns are unanchored; a rule that means "the whole value" must write
`^...$`.

## 4. Cascading: an absent field yields exactly one violation

If a field is absent and carries `Required` plus other predicates, the result is **one** violation,
from `Required`. Every other predicate returns `NotApplicable`.

Without this, an absent `database.port` with `Required` and `IntRange` would report two violations
saying the same thing, and the count would depend on how many rules happened to be attached. Error
output would then vary with rule-set edits that changed nothing semantically, and cross-language
vectors would become unstable.

## 5. Evaluation is exhaustive, and ordering is total

- **Exhaustive, not short-circuit.** Every rule in phase and in scope is evaluated. All violations
  are reported. An operator fixing configuration wants the complete list, not the first problem.
- **Deterministic order.** Violations are sorted by `(field_path, code)`, both compared as byte
  strings. This is a total order because `(field_path, code)` is unique — enforced by the rule-set
  lint (§7).

Determinism is not cosmetic: conformance vectors compare violation *sequences* across three
implementations, so an unstable order would make them unusable.

## 6. Phase and scope

A rule is evaluated only if **both** gates admit it. A rule excluded by either is *not evaluated at
all* — it produces no verdict, not `NotApplicable`.

**Phase.**

| Evaluation | Rules evaluated |
|---|---|
| Build-time validator (files only) | `PHASE_CONFIG`, `PHASE_BOTH` |
| Runtime resolution (config + secrets) | `PHASE_RESOLVED`, `PHASE_BOTH` |

A `PHASE_RESOLVED` rule referencing a field absent at config phase is simply not evaluated at build
time. This is why the distinction exists: without it the build-time validator would fail on rules
whose inputs cannot exist yet.

**Scope.** A rule applies to environment `e` iff
`(scope.kinds is empty ∨ kind(e) ∈ scope.kinds) ∧ kind(e) ∉ scope.except_kinds`.
`except_kinds` is applied after `kinds`, so the two can be combined.

**`EqualAcrossEnvs`** is the one predicate that is not a function of a single instance. It is
evaluated **only by the build-time validator**, which sees every instance, and compares the field
across all environments in scope. At runtime, where only one instance is loaded, it is not
evaluated. A violation is reported once, against the field path, listing the environments that
disagree.

## 7. Rule-set lint (meta-rules)

The rule set is the security boundary of this design, so it is itself checked. These are build-time
failures, not warnings:

1. **Every schema field carries at least one rule.** A field added with no constraints fails the
   build. Without this, the schema can grow past the rule set silently — which is the exact failure
   this system replaces.
2. **`code` is unique** across the rule set. Required for the total ordering in §5 and for vectors
   to identify a violation unambiguously.
3. **`field_path` resolves** against the schema descriptor.
4. **Predicate and field type agree** — `IntRange` on a numeric field, `Matches`/`NonEmpty` on a
   string, `OneOf`/`ForbiddenValue` naming values that exist in that enum.
5. **Every rule has a negative fixture** (§8).

## 8. Negative fixtures: deleting a rule must fail a test

Every rule has a committed fixture that violates it and MUST be rejected, naming that rule's `code`.

This is the property that makes the rule set self-defending. A rule set with only valid fixtures
stays green when a rule is *removed* — and silent weakening of a check is precisely the failure mode
that motivated this work. With a negative fixture per rule, deletion turns a test red.

## 9. What this does not cover

A verified engine faithfully applies whatever rules it is given. It cannot detect that the rule set
**forgot** a rule — that a new field should have been constrained more tightly than "present". That
is spec completeness, not correctness, and no rigor on the engine touches it.

This is worth stating plainly because a verified engine is a *stronger* green signal, and therefore
carries more false confidence when the rule set is thin. The mitigations are mechanical, not
intentional: the meta-rule in §7.1 forces every field to carry a rule, the negative fixtures in §8
prevent silent removal, and the rule set is CODEOWNERS-gated and small enough to read in one sitting.

## 10. Conformance obligations

An implementation conforms iff:

1. Every predicate matches §3, including both inclusive bounds and the absence column.
2. Cascading matches §4 — exactly one violation for an absent required field.
3. Evaluation is exhaustive and violations are ordered per §5.
4. Phase and scope gating matches §6.
5. It reproduces every conformance vector in `config/vectors/`, including **violation identity**
   (`code` and `field_path`), not merely accept/reject.
6. Its predicates satisfy the property-based laws: `OneOf` agrees with set membership, `IntRange` is
   monotone in its bounds, `Required` is the negation of absence, and every predicate is total over
   generated inputs including absence.
