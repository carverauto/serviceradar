---- MODULE CounterBase ----
\* Helper module for the tlc_test self-test; proves deps resolve in the sandbox.
EXTENDS Naturals
Step(n) == n + 1
====
