defmodule ServiceRadar.Edge.AssignmentValidate do
  @moduledoc """
  Elixir peer of Go's `edgerecord.ValidateSweepAssignmentRecord` and
  `edgerecord.ValidateAssignmentAgainstPlan` (task 1.3), plus the COMPOSED boundary
  from raw bytes.

  `SemanticValidate` polices ENUM ADMISSION over the decoded graph; it says nothing
  about lease/fence, required presence, or the assignment-to-plan relation. Without
  this module a record Go rejects -- an empty lease, a zero fence token, an
  expectation whose count and commitment disagree -- returned `:ok` from every Elixir
  entry point.

  ## Two structural rules

    1. `validate_against_plan/3` VALIDATES THE PLAN ITSELF, from the header and pages.
       An earlier revision took an "opaque" carrier and claimed an unvalidated plan was
       not expressible -- but `@opaque` is Dialyzer metadata, so the tuple was forgeable
       around a rejected plan and the relation accepted it. Running the validation
       internally is the only construction that actually holds. An unvalidated plan is
       not a weaker check: whoever supplies it chooses the range digests and windows the
       expectation is compared against.
    2. Raw bytes go through `validate_bytes/1` / `validate_bytes_against_plan/3`, which
       delegate decoding to `WireDecode` so the deliberate `:poison` / `:not_ready` /
       `:systemic` classification is preserved, then run enum admission, then these
       relations. A caller holding only a decoded struct has already skipped the wire
       layer, where retained unknown fields and wire-hygiene violations live.

  Every reason is TYPED and mirrors the Go error it corresponds to, because a shared
  reject vector has to assert WHY a record was refused, not merely that it was.
  """

  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.SweepAssignmentRecordV1
  alias ServiceRadar.Edge.WireDecode

  @sha256_len 32
  @max_policy_id_bytes 128
  # Mirrors Go's MaxMtrCompletionOrdinals (2^31): the ordinal SPACE bound.
  @max_mtr_ordinals 2_147_483_648

  # The accepted states come from the SHARED policy table, not a second local list: a
  # duplicate would drift from `SemanticValidate` silently, which is the same
  # hand-maintained-parity failure the disposition enum was consolidated to remove.
  @known_states Map.fetch!(
                  SemanticValidate.enum_field_policy(),
                  {SweepAssignmentRecordV1, :state}
                )

  @type reason ::
          :identity
          | :scope
          | :lease
          | :state
          | :expectation
          | :unknown_fields
          | :plan_relation

  @doc """
  Composed boundary: RAW BYTES -> structural wire check -> decode -> enum admission ->
  record relations. This is the entry point a consumer should hold.
  """
  @spec validate_bytes(binary()) :: {:ok, struct()} | {:error, term()}
  def validate_bytes(bytes) do
    # WireDecode owns the structural gate AND the classification: a local rescue that
    # maps everything to :poison would turn a codegen or not-yet-deployed-module fault
    # into permanent quarantine instead of a pause.
    with {:ok, record} <- WireDecode.decode_assignment_record(bytes),
         :ok <- SemanticValidate.validate_message(record),
         :ok <- validate(record) do
      {:ok, record}
    end
  end

  @doc """
  Composed boundary, then the plan relation. The PLAN IS VALIDATED HERE, from the
  header and pages, so no caller can substitute an unvalidated one.
  """
  @spec validate_bytes_against_plan(binary(), term(), term()) ::
          {:ok, struct()} | {:error, term()}
  def validate_bytes_against_plan(bytes, header, pages) do
    with {:ok, record} <- validate_bytes(bytes),
         :ok <- validate_against_plan(record, header, pages) do
      {:ok, record}
    end
  end

  @doc """
  Fail-close one append-only assignment record on its own terms.

  TOTAL: any term is accepted and answered with a typed reason -- a validator whose
  contract promises `{:error, reason}` must not raise `KeyError` on a shape it did not
  expect.
  """
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(r) when is_map(r) do
    with :ok <- no_unknown_fields(r),
         :ok <- validate_identity(r),
         :ok <- validate_scope(r),
         :ok <- validate_lease(r),
         :ok <- validate_state(r) do
      validate_expectation(Map.get(r, :mtr_expectation))
    end
  end

  def validate(_), do: {:error, :identity}

  @doc """
  Fail-close the assignment/plan RELATION against an ALREADY-VALIDATED plan,
  recomputing the expectation from committed plan data.
  """
  @spec validate_against_plan(term(), term(), term()) :: :ok | {:error, term()}
  def validate_against_plan(r, header, pages) do
    # The plan is validated HERE. An earlier revision took an "opaque" carrier and
    # claimed a caller could not supply an unvalidated plan -- but `@opaque` is
    # Dialyzer metadata, so the tuple was forgeable around a rejected plan and this
    # function accepted it. Running the validation internally is the only construction
    # that actually holds.
    with :ok <- validate(r),
         {:ok, windows} <- PlanValidate.validate(header, pages),
         :ok <- same_plan(r, header) do
      case PlanValidate.find_range(pages, Map.get(r, :target_range_id)) do
        nil ->
          {:error, :plan_relation}

        range ->
          if range.range_sha256 == Map.get(r, :target_range_sha256) do
            expectation_matches_range(
              Map.get(r, :mtr_expectation),
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

  # Retained unknown fields are rejected on the record AND its nested expectation. A
  # struct that decoded cleanly can still carry bytes no validator walked, and this
  # record is append-only authority: those bytes would ride inside a value later
  # readers treat as settled.
  defp no_unknown_fields(r) do
    unknown = Map.get(r, :__unknown_fields__, [])
    nested = Map.get(Map.get(r, :mtr_expectation) || %{}, :__unknown_fields__, [])

    if unknown == [] and nested == [], do: :ok, else: {:error, :unknown_fields}
  end

  defp same_plan(r, h) do
    # The plan header carries NO assignment epoch (tag 9 retired): an immutable plan
    # must not commit a value that reassignment advances, so the monotonic epoch is
    # the record's alone and is deliberately not compared here.
    if Map.get(r, :execution_plan_id) == Map.get(h, :execution_plan_id) and
         Map.get(r, :execution_plan_sha256) == Map.get(h, :execution_plan_sha256) and
         Map.get(r, :check_set_sha256) == Map.get(h, :check_set_sha256) and
         Map.get(r, :availability_policy_id) == Map.get(h, :availability_policy_id) and
         Map.get(r, :network_scope_id) == Map.get(h, :network_scope_id) do
      :ok
    else
      {:error, :plan_relation}
    end
  end

  defp expectation_matches_range(e, range, offset) do
    cond do
      # v1 replays the SAME COMPLETE window on retry/supersession, so the attempt's
      # count is the range's admitted count -- never a subset of it.
      Map.get(e, :ordinal_count) != range.mtr_ordinal_count ->
        {:error, :plan_relation}

      # REQUIRED PRESENCE: offset 0 is the first range's legal window, so an absent
      # field must not pass as it.
      Map.get(e, :plan_ordinal_offset) != offset ->
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
            if want == Map.get(e, :ordinal_range_commitment),
              do: :ok,
              else: {:error, :plan_relation}
        end
    end
  end

  defp validate_identity(r) do
    # The plan id is a UUIDv7, exactly as Go requires: the plan's identity time is
    # derived from it, so a v4 would silently have no time.
    # record_sequence starts at 1: 0 is the proto default, so accepting it would
    # let an unset field pose as the first record of an append-only series.
    if uuid?(Map.get(r, :producer_assignment_id)) and uuid?(Map.get(r, :execution_id)) and
         PlanValidate.uuidv7?(Map.get(r, :execution_plan_id)) and
         uuid?(Map.get(r, :network_scope_id)) and
         uuid?(Map.get(r, :authenticated_agent_id)) and
         uuid?(Map.get(r, :production_scope_id)) and
         digest?(Map.get(r, :execution_plan_sha256)) and
         pos_int?(Map.get(r, :record_sequence)) and
         pos_int?(Map.get(r, :authored_at_unix_nano)) do
      :ok
    else
      {:error, :identity}
    end
  end

  defp validate_scope(r) do
    if uuid?(Map.get(r, :target_range_id)) and digest?(Map.get(r, :target_range_sha256)) and
         digest?(Map.get(r, :check_set_sha256)) and digest?(Map.get(r, :scope_sha256)) and
         digest?(Map.get(r, :contract_bundle_sha256)) and
         bounded_bytes?(Map.get(r, :availability_policy_id), 1, @max_policy_id_bytes) do
      :ok
    else
      {:error, :scope}
    end
  end

  defp validate_lease(r) do
    if bounded_bytes?(Map.get(r, :lease_id), 1, :infinity) and
         pos_int?(Map.get(r, :fence_token)) and
         pos_int?(Map.get(r, :lease_expires_at_unix_nano)) do
      :ok
    else
      {:error, :lease}
    end
  end

  defp validate_state(r) do
    state = Map.get(r, :state)
    superseded = state == :SWEEP_ASSIGNMENT_STATE_SUPERSEDED
    link = binary_or_empty(Map.get(r, :superseded_by_assignment_id))

    cond do
      state not in @known_states ->
        {:error, :state}

      # superseded_by is present EXACTLY when the state is SUPERSEDED, and never names
      # the record itself -- that is a cycle, not a chain.
      superseded and not uuid?(link) ->
        {:error, :state}

      superseded and link == Map.get(r, :producer_assignment_id) ->
        {:error, :state}

      not superseded and link != <<>> ->
        {:error, :state}

      # An OPEN attempt has closed no evidence interval yet.
      state == :SWEEP_ASSIGNMENT_STATE_OPEN and (Map.get(r, :terminal_batch_sequence) || 0) != 0 ->
        {:error, :state}

      true ->
        :ok
    end
  end

  # ABSENT is not ZERO. A record that never stated an expectation is rejected;
  # treating it as "expects nothing" turns a missing authority into a waiver.
  defp validate_expectation(nil), do: {:error, :expectation}

  defp validate_expectation(e) when is_map(e) do
    count = Map.get(e, :ordinal_count)
    commitment = Map.get(e, :ordinal_range_commitment)
    empty = commitment == <<0::256>>

    cond do
      not digest?(commitment) -> {:error, :expectation}
      is_nil(Map.get(e, :plan_ordinal_offset)) -> {:error, :expectation}
      not is_integer(count) or count < 0 or count > @max_mtr_ordinals -> {:error, :expectation}
      # count == 0 <=> the 32-zero empty-set hash, in BOTH directions. This is what
      # makes the zero-MTR rule checkable: the commitment is an additive multiset hash
      # and cannot be inverted to a count.
      count == 0 != empty -> {:error, :expectation}
      true -> :ok
    end
  end

  defp validate_expectation(_), do: {:error, :expectation}

  defp uuid?(v), do: PlanValidate.canonical_uuid?(v)
  defp digest?(v), do: is_binary(v) and byte_size(v) == @sha256_len
  defp pos_int?(v), do: is_integer(v) and v > 0
  defp binary_or_empty(v) when is_binary(v), do: v
  defp binary_or_empty(_), do: <<>>

  defp bounded_bytes?(v, min, :infinity), do: is_binary(v) and byte_size(v) >= min

  defp bounded_bytes?(v, min, max),
    do: is_binary(v) and byte_size(v) >= min and byte_size(v) <= max
end
