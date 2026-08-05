---- MODULE MC ----
EXTENDS OsirisMsgPassing, TLC

\* MV CONSTANT declarations@modelParameterConstants
CONSTANTS
r1, r2, r3
----

\* MV CONSTANT declarations@modelParameterConstants
CONSTANTS
a, b, c
----

\* MV CONSTANT definitions R
const_1589378301396272000 == 
{r1, r2, r3}
----

\* MV CONSTANT definitions V
const_1589378301396273000 == 
{a, b, c}
----

\* SYMMETRY definition
symm_1589378301396274000 == 
Permutations(const_1589378301396272000) \union Permutations(const_1589378301396273000)
----

\* CONSTRAINT definition @modelParameterContraint:0
constr_1589378301396275000 ==
/\ coord_epoch < 4
/\ start_stop_ctr < 4
----
=============================================================================
\* Modification History
\* Created Thu Jan 30 02:13:29 PST 2020 by jack
