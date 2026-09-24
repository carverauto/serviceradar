defmodule ServiceRadar.Edge.SweepOutcomePolicy do
  @moduledoc """
  The MTR trace-allocation policy, in a module that depends on NEITHER of its consumers.

  `SweepCorrelate` needs it to decide whether a trace time falls in the signed window;
  `SweepBodyValidate` needs it to decide whether a trace id must be present. Holding it in
  either one makes the other depend on its peer, and once the body validator is routed into
  the correlation path (task 1.2-c step 3) that edge becomes MUTUAL -- which contradicts the
  one-way edge the ledger records. A neutral module keeps the direction stated there true.

  Exactly Go's `mtrOutcomeAllocated`: these four outcomes allocate a trace id, and only
  these four carry a trace time the signed window applies to. `MTR_OUTCOME_NOT_ADMITTED`,
  `MTR_OUTCOME_QUARANTINED` and `MTR_OUTCOME_SCHEDULER_LOST` are terminal but allocate
  nothing, so they must carry NO trace id.

  The TERMINAL set is a different question and is not restated here -- it is the admitted
  domain of `SweepMtrSummaryV1.outcome` in `SemanticValidate.enum_field_policy/0`. This
  module's set is asserted to be a proper subset of it.
  """

  @trace_allocating [
    :MTR_OUTCOME_REACHED,
    :MTR_OUTCOME_TARGET_UNREACHABLE,
    :MTR_OUTCOME_PROBE_FAILED,
    :MTR_OUTCOME_TIMED_OUT
  ]

  @doc "The outcomes that allocate a trace id."
  @spec trace_allocating_outcomes() :: [atom()]
  def trace_allocating_outcomes, do: @trace_allocating

  @doc "Whether an outcome allocates a trace id."
  @spec trace_allocated?(term()) :: boolean()
  def trace_allocated?(outcome), do: outcome in @trace_allocating
end
