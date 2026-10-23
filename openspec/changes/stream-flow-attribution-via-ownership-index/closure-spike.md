# Finite diagnostic capture: bounded spike result

Decision 13's source investigation found no acceptable closure implementation under
the existing loader, privilege and whole-host coverage constraints. This is a negative
feasibility result for the candidates examined, not a proof that every possible
mechanism is impossible. The experimental collector remains unpublished. No runtime
code, dependency change, new privilege, rollout or live measurement is part of this PR.

All Phase 0 measurement gates remain open. In particular, these checks do not supply
streaming attribution's direction, listener coverage, history or summary-cap results,
or exposure task 0.5's missing address intervals and mapped evidence batches. The
synthetic shard-store benchmark in [PR #5937][store-pr] is separate evidence and does
not establish capture closure or the full shard gate.

## Three independent proof obligations

| Obligation | Finding | Consequence |
| --- | --- | --- |
| Bootstrap | A function invocation already in progress when hooks attach need not acquire a new entry ticket or return trampoline. A fresh syscall-entry observation can establish that an earlier synchronous syscall returned for the same user-task incarnation, but kernel threads do not cross that boundary. | A census and elapsed warm-up cannot certify the approved whole-host population. Excluding kernel tasks would change scope and is not approved. |
| Completion time | For observed entry E, physical successful return C and exit callback observation X, the evidence supplies E <= C <= X. If E < T <= X at boundary T, C may be on either side. | Reject affected intervals and dependent state unless stronger source evidence orders C. Do not assign C to X's interval or discard the last interval. |
| Terminal barrier | No examined mechanism combines preserved pending exits, settled pre-counter dispatch and failures, observable completion, and support from the pinned loader under the existing privileges. | A drained ring, zero active callback count, detached hook or elapsed timeout cannot certify a terminal receipt. |

Task identity also needs independent proof. Linux `de_thread` can transfer the old
leader's PID, `start_time` and `start_boottime` to a different task during exec. A
PID plus either start timestamp is therefore not an immutable task incarnation
across that transition. A task-exit trace is too early to stand in for completion
of all cleanup: `do_exit` emits it before `exit_files`. These findings come from
[exec identity transfer][exec] and [exit ordering][exit], not a captured host trace.

## Mechanisms examined

The source review covered upstream Linux 6.8 and 6.14 implementations, plus the
older per-link fprobe design. These are public source versions, not deployment
identifiers or an eligible-kernel allowlist. Distribution backports and actual
attachment behavior still require separate validation.

| Candidate | Why it does not establish the required proof |
| --- | --- |
| Ordinary FEntry/FExit detach and `membarrier(GLOBAL)` | Trampoline retirement includes asynchronous Tasks RCU work outside the ordinary RCU region. FExit teardown can patch the return path to skip the callback after a successful target return but before any diagnostic counter. An ordinary RCU wait cannot recover that record. See [trampoline teardown][trampoline] and [x86 trampoline generation][x86]. |
| Per-link kprobe-multi sentinel | The [older fprobe teardown][old-fprobe] can reach a synchronous Tasks RCU wait. The [6.14 shared-graph design][new-fprobe] does not guarantee the same wait with another probe present. Aya 0.13.1 has no public multi-probe load/attach API. A new loader shim or dependency upgrade is outside this spike; even a suitable sentinel would not itself preserve pending exits. |
| Private `ftrace:function` perf event | A private dynamic ftrace operation offers a promising source wait on final destruction, but Aya's perf API attaches BPF and the kernel rejects that attachment for this event class. A bare perf event also registers before a later filter ioctl; `disabled=1` does not provide filter-before-registration. Close does not expose unregister failure. This would require new raw event ownership, bounded activation and failure-observation work. See [perf trace lifecycle][perf-trace], [event creation][perf-core], [ftrace shutdown][ftrace] and [Aya perf attachment][aya-perf]. |
| Ordinary KProbe/KRetProbe replacement | The BPF callback precedes perf-buffer allocation, avoiding that particular loss point, but x86 ftrace recursion rejection can happen before the kprobe miss counter or BPF accounting. BPF perf-link fdinfo does not expose the needed misses; the info syscall is a different interface. KRetProbe unregister can suppress pending return handlers. These are independent of ring-drain success. See [kprobe trace path][trace-kprobe], [BPF link operations][bpf-links], [x86 recursion guard][kprobe-ftrace] and [return-handler retirement][kprobes]. |

The loader constraint is the repository's pinned Aya 0.13.1, whose public
[program interfaces][aya-programs] lack the multi-probe and bare filtered ftrace-event
ownership required by those candidates. The review found no supported way to turn
global program/link enumeration into a bounded owned-link proof after privilege drop.
No dependency or loader was changed to work around these findings.

## Conditional accounting contract

If a future source mechanism establishes the missing proofs, entry accounting must
cover every operation that can change relevant state, including failed operations and
receive peeks. Those do not count as successful summary messages, but can still bind a
socket or otherwise affect ownership state. The required order is:

```text
unseen -> tracked before effects -> target returned -> exit accounted -> retired
```

The ticket needs an independently proven task incarnation, hook identity and entry
time. Exit must match it exactly and publish either its record or an explicit loss
before retirement. Nested operations must be represented without overwriting an
outer ticket, or make coverage unavailable. Missing entries, map failure, overflow,
recursion rejection and ambiguous identities must invalidate coverage. A timeout or
PID reuse must not erase unresolved state.

Keep exit observation available through the cutoff. A pending entry before the
cutoff blocks closure; a completion bracket crossing an interval boundary prevents
exact placement. A source barrier must settle pre-cutoff dispatch and failure
accounting, including work before the collector's own entry counter. Only then can
publication drain and fixed scalar terminal delivery certify the same session,
endpoint and final sequence. These are obligations, not an implemented mechanism.

## Executable evidence and limits

The two bounded [TLA+ models](closure-model/README.md) use the existing remote TLC
test harness. Sixteen checks passed in the [focused run][model-run]. The conditional
safe models exhausted 185 and 446 distinct states. Named counterexamples cover
callback-time substitution, startup frames, nested ticket overwrite, retirement
before publication, absent or failed barriers, delayed loss, missing or conflicting
receipts, and receipt reuse after restart. A separate witness exhibits identical
E=1 and X=2 observations with C=1 or C=2 in different intervals. Populated acceptance
and deadline rejection are both reachable, so the safety checks do not merely reject
every capture.

The integrated branch's [focused check][integrated-run] passed all sixteen targets
from cache. The [full repository unit gate][unit-run] passed 447 targets and skipped
the iOS compile and Swift regression targets. Strict OpenSpec validation also passed.

The models supply an abstract source barrier and bootstrap condition; they do not
prove how to implement either on Linux. They do not model task-generation acquisition,
real scheduler fairness, warehouse delivery or failed-call ownership effects. Their
value is preserving executable counterexamples and conditional protocol invariants,
not certifying a collector. All constants and event histories are synthetic. No live
kernel attachment, terminal receipt, warehouse audit or workload restart was tested.

The models are checked separately; their composition and propagation of rejected
intervals into later state/history are unproven. Their small bounds do not establish
arbitrary concurrency or capacity behavior. A terminal token abstracts the full
scalar set, endpoint/sequence agreement and replay, and revoking an audit verdict
does not undo earlier consumer actions. The [choices audit](choices.md) records
these limits and the scope of this separate evidence PR.

The next runtime step requires a concrete, source-supported architecture decision
that resolves all three obligations. Any change to loader, privileges or covered
population must return for coordinator review. Until then tasks 0.6-0.8 remain
exploratory, task 0.10 remains open, and P2-P8 must not start.

[store-pr]: https://github.com/carverauto/serviceradar/pull/5937
[model-run]: https://carverauto.buildbuddy.io/invocation/89e93073-f1da-4840-87da-6628c9156867
[integrated-run]: https://carverauto.buildbuddy.io/invocation/6b5e4229-fb53-42ae-8ee3-c04f23a124b5
[unit-run]: https://carverauto.buildbuddy.io/invocation/7df0985a-3197-4b52-8937-5a162ab6ba0f
[exec]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/fs/exec.c
[exit]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/kernel/exit.c
[trampoline]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/kernel/bpf/trampoline.c
[x86]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/arch/x86/net/bpf_jit_comp.c
[old-fprobe]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/kernel/trace/fprobe.c
[new-fprobe]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.14/kernel/trace/fprobe.c
[perf-trace]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.14/kernel/trace/trace_event_perf.c
[perf-core]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.14/kernel/events/core.c
[ftrace]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.14/kernel/trace/ftrace.c
[aya-perf]: https://docs.rs/aya/0.13.1/src/aya/programs/perf_event.rs.html
[aya-programs]: https://docs.rs/aya/0.13.1/aya/programs/index.html
[trace-kprobe]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/kernel/trace/trace_kprobe.c
[bpf-links]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.14/kernel/bpf/syscall.c
[kprobe-ftrace]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/arch/x86/kernel/kprobes/ftrace.c
[kprobes]: https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/refs/tags/v6.8/kernel/kprobes.c
