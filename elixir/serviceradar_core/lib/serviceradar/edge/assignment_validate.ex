defmodule ServiceRadar.Edge.AssignmentValidate do
  @moduledoc """
  Elixir peer of Go's `edgerecord.ValidateSweepAssignmentRecord` and
  `edgerecord.ValidateAssignmentAgainstPlan` (task 1.3).

  `SemanticValidate` polices ENUM ADMISSION over the decoded graph; it says nothing
  about lease/fence, required presence, or the assignment-to-plan relation. Without
  this module a record that Go rejects -- an empty lease, a zero fence token, an
  expectation whose count and commitment disagree -- returned `:ok` from every Elixir
  entry point, so "both runtimes validate the assignment" was false.

  Every reason is TYPED and mirrors the Go error it corresponds to, because a shared
  reject vector has to assert WHY a record was refused, not merely that it was.

  ## Relation, not two independent checks

  `validate_against_plan/3` recomputes the MTR expectation from committed plan data
  rather than trusting the carried bytes. In v1 an assignment covers exactly ONE plan
  range and the completion proof requires leaf ordinals `{1..ordinal_count}`, so the
  count and the range digest DETERMINE the commitment. Accepting whatever the record
  carried would leave the per-attempt MTR authority self-asserted -- the defect this
  contract exists to remove.
  """

  alias ServiceRadar.Edge.HashGrammar

  @sha256_len 32
  @uuid_len 16
  @max_policy_id_bytes 128

  @terminal_states [
    :SWEEP_ASSIGNMENT_STATE_COMPLETED,
    :SWEEP_ASSIGNMENT_STATE_ABORTED,
    :SWEEP_ASSIGNMENT_STATE_LOST,
    :SWEEP_ASSIGNMENT_STATE_EXPIRED,
    :SWEEP_ASSIGNMENT_STATE_SUPERSEDED
  ]
  @known_states [:SWEEP_ASSIGNMENT_STATE_OPEN | @terminal_states]

  @type reason ::
          :identity
          | :scope
          | :lease
          | :state
          | :expectation
          | :plan_relation

  @doc """
  Fail-close one append-only assignment record on its own terms.

  Mirrors `edgerecord.ValidateSweepAssignmentRecord`: nothing here is corroborated
  against a producer's lifecycle event, because the record exists to be the authority
  that event is not.
  """
  @spec validate(map()) :: :ok | {:error, reason()}
  def validate(r) when is_map(r) do
    with :ok <- validate_identity(r),
         :ok <- validate_scope(r),
         :ok <- validate_lease(r),
         :ok <- validate_state(r) do
      validate_expectation(r.mtr_expectation)
    end
  end

  def validate(_), do: {:error, :identity}

  @doc """
  Fail-close the assignment/plan RELATION, recomputing the expectation from the
  committed plan.

  Mirrors `edgerecord.ValidateAssignmentAgainstPlan`. Each artifact can be internally
  valid while describing a DIFFERENT plan, which validating them independently cannot
  notice.
  """
  @spec validate_against_plan(map(), map(), [map()]) :: :ok | {:error, reason()}
  def validate_against_plan(r, header, pages) do
    with :ok <- validate(r),
         :ok <- same_plan(r, header),
         {:ok, windows, _total} <- windows_or_error(pages) do
      case find_range(pages, r.target_range_id) do
        nil ->
          {:error, :plan_relation}

        range ->
          if range.range_sha256 == r.target_range_sha256 do
            expectation_matches_range(
              r.mtr_expectation,
              range,
              Map.fetch!(windows, range.range_id)
            )
          else
            # Right identity, wrong content: a claimed range whose digest is not the
            # plan's is a substitution, not a near miss.
            {:error, :plan_relation}
          end
      end
    end
  end

  defp windows_or_error(pages) do
    case HashGrammar.plan_mtr_windows(pages) do
      :error -> {:error, :plan_relation}
      ok -> ok
    end
  end

  defp find_range(pages, range_id) do
    pages
    |> Enum.flat_map(& &1.ranges)
    |> Enum.find(&(&1.range_id == range_id))
  end

  defp same_plan(r, h) do
    # The plan header carries NO assignment epoch (tag 9 retired): an immutable plan
    # must not commit a value that reassignment advances, so the monotonic epoch is
    # the record's alone and is deliberately not compared here.
    if r.execution_plan_id == h.execution_plan_id and
         r.execution_plan_sha256 == h.execution_plan_sha256 and
         r.check_set_sha256 == h.check_set_sha256 and
         r.availability_policy_id == h.availability_policy_id and
         r.network_scope_id == h.network_scope_id do
      :ok
    else
      {:error, :plan_relation}
    end
  end

  defp expectation_matches_range(e, range, offset) do
    cond do
      # v1 replays the SAME COMPLETE window on retry/supersession, so the attempt's
      # count is the range's admitted count -- never a subset of it.
      e.ordinal_count != range.mtr_ordinal_count ->
        {:error, :plan_relation}

      # REQUIRED PRESENCE: offset 0 is the first range's legal window, so an absent
      # field must not pass as it.
      is_nil(e.plan_ordinal_offset) or e.plan_ordinal_offset != offset ->
        {:error, :plan_relation}

      true ->
        case HashGrammar.mtr_window_commitment(
               offset,
               range.mtr_ordinal_count,
               range.range_sha256
             ) do
          :error ->
            {:error, :plan_relation}

          want ->
            if want == e.ordinal_range_commitment,
              do: :ok,
              else: {:error, :plan_relation}
        end
    end
  end

  defp validate_identity(r) do
    # record_sequence starts at 1: 0 is the proto default, so accepting it would
    # let an unset field pose as the first record of an append-only series.
    if uuid?(r.producer_assignment_id) and uuid?(r.execution_id) and
         uuid?(r.execution_plan_id) and uuid?(r.network_scope_id) and
         uuid?(r.authenticated_agent_id) and uuid?(r.production_scope_id) and
         digest?(r.execution_plan_sha256) and
         is_integer(r.record_sequence) and r.record_sequence >= 1 and
         is_integer(r.authored_at_unix_nano) and r.authored_at_unix_nano > 0 do
      :ok
    else
      {:error, :identity}
    end
  end

  defp validate_scope(r) do
    policy_len = byte_size(r.availability_policy_id || <<>>)

    if uuid?(r.target_range_id) and digest?(r.target_range_sha256) and
         digest?(r.check_set_sha256) and digest?(r.scope_sha256) and
         digest?(r.contract_bundle_sha256) and
         policy_len > 0 and policy_len <= @max_policy_id_bytes do
      :ok
    else
      {:error, :scope}
    end
  end

  defp validate_lease(r) do
    if byte_size(r.lease_id || <<>>) > 0 and
         is_integer(r.fence_token) and r.fence_token > 0 and
         is_integer(r.lease_expires_at_unix_nano) and r.lease_expires_at_unix_nano > 0 do
      :ok
    else
      {:error, :lease}
    end
  end

  defp validate_state(r) do
    superseded = r.state == :SWEEP_ASSIGNMENT_STATE_SUPERSEDED
    link = r.superseded_by_assignment_id || <<>>

    cond do
      r.state not in @known_states ->
        {:error, :state}

      # superseded_by is present EXACTLY when the state is SUPERSEDED, and never names
      # the record itself -- that is a cycle, not a chain.
      superseded and not uuid?(link) ->
        {:error, :state}

      superseded and link == r.producer_assignment_id ->
        {:error, :state}

      not superseded and byte_size(link) > 0 ->
        {:error, :state}

      # An OPEN attempt has closed no evidence interval yet.
      r.state == :SWEEP_ASSIGNMENT_STATE_OPEN and (r.terminal_batch_sequence || 0) != 0 ->
        {:error, :state}

      true ->
        :ok
    end
  end

  # ABSENT is not ZERO. A record that never stated an expectation is rejected;
  # treating it as "expects nothing" turns a missing authority into a waiver.
  defp validate_expectation(nil), do: {:error, :expectation}

  defp validate_expectation(e) do
    empty = e.ordinal_range_commitment == <<0::256>>

    cond do
      not digest?(e.ordinal_range_commitment) -> {:error, :expectation}
      is_nil(e.plan_ordinal_offset) -> {:error, :expectation}
      not is_integer(e.ordinal_count) or e.ordinal_count < 0 -> {:error, :expectation}
      # count == 0 <=> the 32-zero empty-set hash, in BOTH directions. This is what
      # makes the zero-MTR rule checkable: the commitment is an additive multiset hash
      # and cannot be inverted to a count.
      e.ordinal_count == 0 != empty -> {:error, :expectation}
      true -> :ok
    end
  end

  defp uuid?(v), do: is_binary(v) and byte_size(v) == @uuid_len
  defp digest?(v), do: is_binary(v) and byte_size(v) == @sha256_len
end
