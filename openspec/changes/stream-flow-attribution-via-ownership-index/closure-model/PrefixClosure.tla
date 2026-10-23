--------------------------- MODULE PrefixClosure ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Bug
VARIABLE s
vars == <<s>>
Ops == {"outer", "inner"}
Init == s = [phase |-> "boot", old |-> TRUE, unreported |-> FALSE,
             entered |-> {}, active |-> {}, pending |-> {}, queue |-> {},
             published |-> {}, loss |-> FALSE, injected |-> FALSE,
             bad |-> FALSE, barrier |-> "none", budget |-> 0,
             token |-> 1, receipt |-> 0, delivered |-> 0,
             conflict |-> FALSE, accepted |-> FALSE]
(* An uninstrumented startup frame has no entry or exit record. *)
OldReturn == /\ s.old
             /\ s' = [s EXCEPT !.old = FALSE,
                       !.unreported = s.phase # "boot"]
Begin == /\ s.phase = "boot" /\ (~s.old \/ Bug = "startup")
         /\ s' = [s EXCEPT !.phase = "run"]
Enter(op) ==
    /\ s.phase = "run" /\ op \notin s.entered
    /\ (op = "inner" => "outer" \in s.active)
    /\ s' = [s EXCEPT !.entered = @ \cup {op}, !.active = @ \cup {op},
              !.pending = IF Bug = "nested" THEN {op} ELSE @ \cup {op},
              !.bad = @ \/ (op = "inner" /\ Bug # "nested")]
(* Return/callback ordering is abstract here; CompletionBracket owns C vs X.
   queue is downstream publication work, not a running kernel callback. *)
Complete(op) == /\ op \in s.active
                /\ (op = "outer" => "inner" \notin s.active)
                /\ s' = [s EXCEPT !.active = @ \ {op}, !.queue = @ \cup {op}]
Publish(op) == /\ op \in s.queue
               /\ s' = [s EXCEPT !.queue = @ \ {op}, !.published = @ \cup {op}]
Remove(op) == /\ op \in s.pending
              /\ (op \in s.published \/ Bug = "early_remove")
              /\ s' = [s EXCEPT !.pending = @ \ {op}]
Stop == /\ s.phase = "run"
        /\ s' = [s EXCEPT !.phase = "closing"]
(* Cause is in the prefix; its observation may be delayed past the receipt. *)
LatentLoss == /\ s.phase = "closing" /\ s.barrier = "none" /\ ~s.injected
              /\ s' = [s EXCEPT !.loss = TRUE, !.injected = TRUE]
ObserveLoss == /\ s.loss
               /\ s' = [s EXCEPT !.loss = FALSE, !.bad = TRUE, !.accepted = FALSE]
(* An ABSTRACT source proof: no tracked callback remains; all latent failures
   are settled. This action is an obligation, not a proposed kernel mechanism. *)
Barrier(result) ==
    /\ s.phase = "closing" /\ s.barrier = "none"
    /\ (result = "pass" =>
          (s.active = {} /\ (~s.loss \/ Bug = "late_loss")))
    /\ s' = [s EXCEPT !.barrier = result]
Issue ==
    /\ s.phase = "closing" /\ s.receipt = 0 /\ s.pending = {} /\ ~s.bad
    /\ (s.barrier = "pass"
        \/ (Bug = "missing_barrier" /\ s.barrier = "none")
        \/ (Bug = "failed_barrier" /\ s.barrier = "fail"))
    /\ s' = [s EXCEPT !.receipt = s.token]
Deadline ==
    /\ s.phase = "closing" /\ s.receipt = 0 /\ s.budget < 2
    /\ s' = [s EXCEPT !.budget = @ + 1,
              !.phase = IF s.budget = 1 THEN "expired" ELSE @,
              !.bad = @ \/ s.budget = 1]
Deliver == /\ s.receipt # 0 /\ s.delivered # s.receipt
           /\ s' = [s EXCEPT !.delivered = s.receipt]
Audit ==
    /\ ~s.accepted /\ ~s.bad /\ ~s.conflict
    /\ ((s.delivered # 0 /\ (s.delivered = s.token \/ Bug = "restart"))
        \/ (Bug = "missing_receipt" /\ s.receipt = s.token /\ s.delivered = 0))
    /\ s' = [s EXCEPT !.accepted = TRUE]
Contradict ==
    /\ s.delivered # 0 /\ ~s.conflict
    /\ s' = [s EXCEPT !.conflict = TRUE,
              !.accepted = IF Bug = "contradiction" THEN @ ELSE FALSE]
Restart == /\ s.accepted /\ s.token = 1
           /\ s' = [s EXCEPT !.token = 2, !.receipt = 0, !.accepted = FALSE,
                     !.barrier = "none", !.phase = "expired"]
Next == OldReturn \/ Begin \/ Stop \/ LatentLoss \/ ObserveLoss
        \/ (\E op \in Ops : Enter(op) \/ Complete(op) \/ Publish(op) \/ Remove(op))
        \/ (\E result \in {"pass", "fail"} : Barrier(result))
        \/ Issue \/ Deadline \/ Deliver \/ Audit \/ Contradict \/ Restart
Spec == Init /\ [][Next]_vars
CertifiedPrefix == s.accepted =>
    /\ ~s.old /\ ~s.unreported /\ ~s.loss /\ ~s.bad /\ ~s.conflict
    /\ s.active = {} /\ s.entered \subseteq s.published
    /\ s.barrier = "pass" /\ s.receipt = s.token /\ s.delivered = s.token
NeverAcceptsPopulated == ~(s.accepted /\ "outer" \in s.published)
NeverExpiresUnpublished == ~(s.phase = "expired" /\ "outer" \in s.queue)
=============================================================================
