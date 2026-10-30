defmodule ServiceRadar.Edge.LifecycleValidate do
  @moduledoc """
  Structural peer of Go's `ValidateSweepExecutionEvent` for decoded lifecycle events.

  Validates identity, emission time, lifecycle kind, completion counters and proof
  shape, and the conditional abort reason. It does not verify signatures, resolve
  assignments or recompute completion proofs against authoritative plan state.
  Retained unknown fields are refused; callers with raw bytes still need wire hygiene.
  """

  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.SweepExecutionEventV1

  @u32_max 4_294_967_295
  @u64_max 18_446_744_073_709_551_615
  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807
  @completion_version 2
  @max_reason_bytes 256

  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%SweepExecutionEventV1{} = event) do
    with :ok <- shape(event),
         :ok <- SemanticValidate.validate_message(event),
         :ok <- identity(event),
         :ok <- completion(event) do
      abort_reason(event)
    end
  end

  def validate(_), do: {:error, :shape}

  # This message is flat. Read each scalar's declared type so a newly added
  # unsupported kind cannot silently bypass the decoded-shape precondition.
  defp shape(event) do
    cond do
      Map.keys(event) != Map.keys(%SweepExecutionEventV1{}) ->
        {:error, :shape}

      event.__unknown_fields__ != [] ->
        {:error, :unknown_fields}

      Enum.all?(SweepExecutionEventV1.__message_props__().field_props, fn {_tag, field} ->
        not field.repeated? and not field.embedded? and not field.proto3_optional? and
            scalar?(field.type, Map.fetch!(event, field.name_atom))
      end) ->
        :ok

      true ->
        {:error, :shape}
    end
  end

  defp scalar?(:bytes, value), do: is_binary(value)
  defp scalar?(:string, value), do: is_binary(value) and String.valid?(value)
  defp scalar?(:uint32, value), do: integer?(value, 0, @u32_max)
  defp scalar?(:uint64, value), do: integer?(value, 0, @u64_max)
  defp scalar?(:int64, value), do: integer?(value, @i64_min, @i64_max)

  defp scalar?({:enum, _}, value),
    do: is_atom(value) or integer?(value, -2_147_483_648, 2_147_483_647)

  defp scalar?(_, _), do: false
  defp integer?(value, first, last), do: is_integer(value) and value >= first and value <= last

  defp identity(event) do
    if Enum.all?(
         [event.execution_id, event.execution_plan_id, event.target_range_id],
         &PlanValidate.canonical_uuid?/1
       ) and
         byte_size(event.execution_plan_sha256) == 32 and event.emitted_at_unix_nano > 0 do
      :ok
    else
      {:error, :identity}
    end
  end

  defp completion(%{kind: :SWEEP_EXECUTION_EVENT_KIND_COMPLETED} = event) do
    cond do
      event.durable_through_batch_sequence > event.terminal_batch_sequence ->
        {:error, :durable_prefix}

      event.emitted_mtr_summaries > event.expected_mtr_summaries or
          event.emitted_mtr_traces > event.expected_mtr_traces ->
        {:error, :mtr_counts}

      event.mtr_completion_digest_version != @completion_version or
        byte_size(event.mtr_completion_digest) != 32 or byte_size(event.plan_root_sha256) != 32 ->
        {:error, :completion_proof}

      true ->
        :ok
    end
  end

  defp completion(%{mtr_completion_digest: ""}), do: :ok
  defp completion(_), do: {:error, :nonterminal_proof}

  defp abort_reason(%{kind: :SWEEP_EXECUTION_EVENT_KIND_ABORTED, abort_reason: reason}) do
    if byte_size(reason) in 1..@max_reason_bytes, do: :ok, else: {:error, :abort_reason}
  end

  defp abort_reason(%{abort_reason: ""}), do: :ok
  defp abort_reason(_), do: {:error, :abort_reason}
end
