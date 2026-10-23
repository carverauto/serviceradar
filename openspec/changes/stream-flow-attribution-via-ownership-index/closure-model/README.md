# Finite closure falsification models

These bounded, synthetic models test Decision 13 protocol obligations. They do
not implement capture or prove any Linux/Aya barrier, bootstrap mechanism,
kernel eligibility, scheduling bound, or live measurement gate.

`CompletionBracket` separates native successful completion C from the callback
observation X. The classifier sees entry E and X only. For half-open intervals,
E < boundary <= X is ambiguous. For example, E=1 and X=3 permit both C=1 and
C=2 with identical observed evidence and different intervals. `twinCompletion`
explicitly witnesses this alternative hidden history with the same E and X.
The safe candidate rejects this bracket; the unsafe candidate assigns X's
interval to C. Time is
bounded to 0..4, with fixed boundaries 2 and 4; no endpoint is moved to obtain
a convenient complete interval. Only successful message completion is modeled
here; failed calls can still change ownership state and need their own bounds.

`PrefixClosure` separates source settlement, downstream publication, terminal
delivery, and audit acceptance. One uninstrumented startup frame must finish
before capture starts. Two operation identities with inner-before-outer return
order exercise nested pending-slot overwrite; this is not a model of Linux
task-generation acquisition. The
abstract barrier settles tracked source callbacks and latent prefix failures,
but does not deliver queued records to the consumer. Source proof must justify
that abstraction independently. The deadline permits two abstract closing ticks;
expiry rejects capture. This checks refusal after expiry, not clock fairness or
a real-time completion bound. Operations may remain pending indefinitely and
cannot yield a successful receipt. Restart changes the session token; absent,
old, or contradictory terminal delivery cannot certify the new session.

Unsafe configurations each require the named invariant violation. A parse
error, different violation, or missing counterexample fails the Bazel target.
The safe configurations explore all modeled interleavings. Nonvacuity targets
require reachable acceptance, including publication of an actual operation;
the deadline target requires refusal while a completed record is still
unpublished. None supplies a kernel proof by injecting a synthetic receipt.

The two models are checked separately; their composition is unproven. Prefix
closure alone does not place completion before an interval cutoff. The bounds
(one startup frame, two operations, two sessions and one latent failure) expose
minimal counterexamples, not arbitrary concurrency or capacity exhaustion.
Neither model propagates a rejected interval into later socket state or history,
and a single C does not describe multiple effects within a call. The terminal
token abstracts away scalar membership, endpoint/sequence agreement and replay.
Revoking `accepted` models the current verdict, not undoing actions an earlier
consumer took. See the [choices audit](../choices.md) for these proof boundaries.

Run all checks remotely from the repository root:

```text
bazel test -c opt --config=remote //openspec/changes/stream-flow-attribution-via-ownership-index/closure-model:all --test_output=all
```
