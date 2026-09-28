---- MODULE Counter ----
\* Self-test for //build/tla:tlc.bzl. Counts 0..3. Bounded holds when Limit >= 3;
\* NeverSkips is violated by every step, so it is the action-property witness.
EXTENDS CounterBase
CONSTANT Limit
VARIABLE x
Init == x = 0
Next == x < 3 /\ x' = Step(x)
Spec == Init /\ [][Next]_x
Bounded == x <= Limit
NeverDecreases == [][x' >= x]_x
NeverSkips == [][x' = x + 2]_x
====
