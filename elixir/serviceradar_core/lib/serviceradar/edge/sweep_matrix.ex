defmodule ServiceRadar.Edge.SweepMatrix do
  @moduledoc """
  The FROZEN `SweepObservationBatchV1` correlation matrix, and the label
  vocabulary shared with Go.

  `ServiceRadar.Edge.SweepCorrelate` consumes this table and emits these labels. It
  is a RELATION, not an authenticated boundary, and it names the Elixir full body
  validator (task 1.2-c) as a precondition rather than enforcing it.

  This is the Elixir peer of Go's `sweepSourceMatrix`, and it is `SweepCorrelate`'s
  SOLE kind lookup: nothing else may derive a source's authorization kind, its signed
  context operand, or its `source_run_id` disposition. That single-lookup property is what makes the exhaustive inventory
  test equal to the behaviour's coverage — five sources against seven declared
  kinds is a 5x7 accept/reject matrix with five accepting cells, so sampling wrong
  kinds per source would exercise five of thirty rejecting cells and leave an
  implementation free to accept an untested pair.

  The kind ordinals deliberately do NOT line up with the source ordinals: only
  `SCHEDULED_SWEEP` and `SWEEP_PROFILE` coincide. Correlating by NUMBER instead of
  by this table accepts an ad-hoc body under scheduled-check authority.

  `SWEEP_EXECUTION_SOURCE_UNSPECIFIED` is deliberately ABSENT. It is the proto
  default, so admitting it would let an unset field select a mapping.
  """

  @typedoc "Which body field this source's signed `context_id` is compared against."
  @type operand :: :execution_id | :source_run_id

  @typedoc "Whether this source may carry `source_run_id`."
  @type disposition :: :required | :forbidden

  @typedoc "A frozen portable rejection label."
  @type label ::
          :source_authority_absent
          | :source_kind
          | :source_run_id_disposition
          | :context_id
          | :range_id
          | :scope_digest
          | :target_range_digest
          | :plan_digest
          | :execution_shard
          | :assignment_epoch
          | :batch_time_window
          | :host_time_window
          | :host_time_overflow
          | :trace_time_window
          | :trace_time_overflow

  @type row :: %{kind: atom(), operand: operand(), source_run_id: disposition()}

  @matrix %{
    :SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP => %{
      kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
      operand: :execution_id,
      source_run_id: :forbidden
    },
    :SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE => %{
      kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE,
      operand: :execution_id,
      source_run_id: :forbidden
    },
    :SWEEP_EXECUTION_SOURCE_AD_HOC => %{
      kind: :EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
      operand: :source_run_id,
      source_run_id: :required
    },
    :SWEEP_EXECUTION_SOURCE_ON_DEMAND => %{
      kind: :EDGE_SOURCE_AUTHORIZATION_KIND_ON_DEMAND,
      operand: :source_run_id,
      source_run_id: :required
    },
    :SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK => %{
      kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
      operand: :source_run_id,
      source_run_id: :required
    }
  }

  @doc """
  The frozen matrix. Exposed so the inventory test can prove it TOTAL, INJECTIVE,
  and free of the two unreachable kinds — properties a vector set cannot
  establish, because vectors sample.
  """
  @spec matrix() :: %{optional(atom()) => row()}
  def matrix, do: @matrix

  @doc "The row for a source, or `:error` when the source selects no mapping."
  @spec fetch(atom()) :: {:ok, row()} | :error
  def fetch(source), do: Map.fetch(@matrix, source)

  @doc "Whether a source is admitted. Derived from the matrix, never a second list."
  @spec known_source?(atom()) :: boolean()
  def known_source?(source), do: Map.has_key?(@matrix, source)

  @doc """
  The FIFTEEN frozen label NAMES.

  The ORDER IS NOT FROZEN — the shared vector manifest that would give an order
  its authority does not exist yet, so the inventory compares an unordered SET and
  this list's sequence is presentation only.

  Labels and gates are ORTHOGONAL: `:source_run_id_disposition` is emitted by the
  BODY validator, the rest by the correlation. A label does not imply a gate.

  Two rejections are deliberately UNLABELLED — enum admission of an unknown sweep
  source, and the reserved recovery lane. Both are pre-existing gates with typed
  per-runtime reasons, and demanding an exact label from them would be
  unsatisfiable against this contract.
  """
  @spec labels() :: [label()]
  def labels do
    [
      :assignment_epoch,
      :batch_time_window,
      :context_id,
      :execution_shard,
      :host_time_overflow,
      :host_time_window,
      :plan_digest,
      :range_id,
      :scope_digest,
      :source_authority_absent,
      :source_kind,
      :source_run_id_disposition,
      :target_range_digest,
      :trace_time_overflow,
      :trace_time_window
    ]
  end

  @doc """
  The two `EdgeSourceAuthorizationKind` members that exist on the wire but are
  OUTSIDE this mapping's range. A sweep record presenting either is rejected, and
  this list SHALL NOT be read as reserving them for later sweep use.

  They are refused by DIFFERENT gates and are not a matching pair:
  `INTEGRATION_RUN` reaches the correlation, while `RECOVERY_CONTROL` is caught
  first by the reserved recovery lane.
  """
  @spec unreachable_kinds() :: [atom()]
  def unreachable_kinds do
    [
      :EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN,
      :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL
    ]
  end

  @doc """
  The `source_run_id` disposition check, decidable from the batch ALONE.

  This belongs to BODY validation, not the correlation: `source` and
  `source_run_id` are fields of the SAME message and no signed authority is
  consulted. Deferring a body-decidable rule past the body validator would carry a
  malformed batch into authority comparison, where the reported reason depends on
  which mismatch is noticed first.

  Where required, `source_run_id` MUST be a canonical UUID — ONE
  source-independent predicate, the same check on every required row.
  """
  @spec check_source_run_id(row(), binary() | nil) :: :ok | {:error, label()}
  def check_source_run_id(%{source_run_id: :forbidden}, id) when id in [nil, ""], do: :ok

  def check_source_run_id(%{source_run_id: :forbidden}, _id),
    do: {:error, :source_run_id_disposition}

  def check_source_run_id(%{source_run_id: :required}, id) do
    if canonical_uuid?(id), do: :ok, else: {:error, :source_run_id_disposition}
  end

  @doc """
  Which body field this source selects as the signed context operand. There is
  exactly ONE selected operand per source and never two: the non-selected field is
  not a second thing the context may agree with.
  """
  @spec context_operand(row(), map()) :: binary()
  def context_operand(%{operand: :source_run_id}, batch), do: Map.get(batch, :source_run_id) || ""
  def context_operand(%{operand: :execution_id}, batch), do: Map.get(batch, :execution_id) || ""

  # A canonical UUID is 16 bytes with a defined version (1-8), the RFC variant-10
  # bits, and is not all-zero. Version 7 is NOT required here.
  defp canonical_uuid?(id) when is_binary(id) and byte_size(id) == 16 do
    <<_::48, ver::4, _::12, var::2, _::62>> = id
    ver >= 1 and ver <= 8 and var == 0b10 and id != <<0::128>>
  end

  defp canonical_uuid?(_), do: false
end
