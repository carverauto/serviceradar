------------------------- MODULE CompletionBracket -------------------------
EXTENDS Integers
CONSTANT ObservationIsCompletion
VARIABLE s
vars == <<s>>
Bucket(t) == t \div 2
Init == s = [now |-> 0, phase |-> "idle", entry |-> -1,
             completion |-> -1, twinCompletion |-> -1, observed |-> -1, reported |-> -1,
             accepted |-> FALSE]
Tick == /\ s.now < 4
        /\ s' = [s EXCEPT !.now = @ + 1]
Enter == /\ s.phase = "idle" /\ s.now \in 1..3
         /\ s' = [s EXCEPT !.phase = "pending", !.entry = s.now]
Return == /\ s.phase = "pending"
          /\ s' = [s EXCEPT !.phase = "returned", !.completion = s.now]
Observe == /\ s.phase = "returned"
           /\ \E other \in s.entry..s.now :
                s' = [s EXCEPT !.phase = "observed", !.observed = s.now,
                       !.twinCompletion = other]
(* C is hidden from the classifier. X is only its upper bound. *)
Unambiguous == \A boundary \in {2, 4} :
                  ~(s.entry < boundary /\ boundary <= s.observed)
Classify == /\ s.phase = "observed"
            /\ s' = [s EXCEPT !.phase = "done",
                      !.accepted = ObservationIsCompletion \/ Unambiguous,
                      !.reported = Bucket(s.observed)]
Next == Tick \/ Enter \/ Return \/ Observe \/ Classify
Spec == Init /\ [][Next]_vars
CompletionPreserved == s.accepted => s.reported = Bucket(s.completion)
EvidenceDeterminesInterval == s.phase = "observed" =>
    Bucket(s.completion) = Bucket(s.twinCompletion)
NeverAccepted == ~s.accepted
=============================================================================
