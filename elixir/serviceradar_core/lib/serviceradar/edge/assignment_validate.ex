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
    2. Raw bytes go through `validate_bytes/1` / `validate_bytes_against_plan_bytes/3`, which
       delegate decoding to `WireDecode` so the deliberate `:poison` / `:not_ready` /
       `:systemic` classification is preserved, then run enum admission, then these
       relations. A caller holding only a decoded struct has already skipped the wire
       layer, where retained unknown fields and wire-hygiene violations live.

  Reasons are TYPED so a shared reject vector can assert WHY a record was refused, not
  merely that it was. They correspond to the Go errors for the RECORD relations -- with
  one deliberate difference: through `validate_bytes/1`, ENUM ADMISSION runs before
  these checks, so an unsupported state surfaces as `{:unsupported_enum, [:state]}`
  rather than `:state`. Both refuse the record; only the layer that speaks first
  differs, and the vectors assert the layered reason rather than pretending otherwise.
  """

  alias ServiceRadar.Edge.BoundedList
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.PlanValidate
  alias ServiceRadar.Edge.SemanticValidate
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1
  alias Serviceradar.Edge.V1.SweepAssignmentRecordV1
  alias Serviceradar.Edge.V1.SweepMtrExpectationV1
  alias ServiceRadar.Edge.WireDecode

  @sha256_len 32
  @max_policy_id_bytes 128
  # Mirrors Go's MaxMtrCompletionOrdinals (2^31): the ordinal SPACE bound.
  @max_mtr_ordinals 2_147_483_648
  @max_manifest_pages 1024

  # The accepted states come from the SHARED policy table, not a second local list: a
  # duplicate would drift from `SemanticValidate` silently, which is the same
  # hand-maintained-parity failure the disposition enum was consolidated to remove.
  @known_states Map.fetch!(
                  SemanticValidate.enum_field_policy(),
                  {SweepAssignmentRecordV1, :state}
                )

  # Same rule for the source-authorization kinds: the SHARED policy table, not a second local
  # list. A hand-maintained copy drifts from `SemanticValidate` silently -- and this one was
  # exactly that, written out longhand right after the comment above explained why not to.
  @source_auth_kinds Map.fetch!(
                       SemanticValidate.enum_field_policy(),
                       {EdgeSourceSpanIdentityV1, :kind}
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
  Composed boundary from RAW bytes on BOTH sides -- the assignment and the plan.

  This is the only entry point that can claim wire-hygiene parity for the plan.
  protobuf-elixir ERASES an unknown GROUP rather than retaining it, so a decoded page
  cannot be asked whether it carried one, while Go retains and rejects it. Only the raw
  structural walk in `WireDecode` sees those bytes.
  """
  @spec validate_bytes_against_plan_bytes(binary(), binary(), [binary()]) ::
          {:ok, struct()} | {:error, term()}
  def validate_bytes_against_plan_bytes(record_bytes, header_bytes, page_bytes)
      when is_list(page_bytes) do
    with {:ok, header} <- WireDecode.decode_plan_header(header_bytes),
         # BOUND FIRST. Decoding an unbounded supplied list before the page limit is
         # checked is attacker-controlled work, and the accumulator was `acc ++ [page]`,
         # making it QUADRATIC as well. The header states how many pages the plan has,
         # so a list that cannot match it is refused without decoding any of it.
         :ok <- bound_page_count(header, page_bytes),
         {:ok, pages} <- decode_pages(page_bytes) do
      validate_bytes_against_plan(record_bytes, header, pages)
    end
  end

  def validate_bytes_against_plan_bytes(_r, _h, _p), do: {:error, :systemic}

  defp bound_page_count(header, page_bytes) do
    declared = Map.get(header, :page_count)

    # BOUNDED COUNT, not `length/1`. The ceiling exists to stop unbounded work, so measuring the
    # whole supplied list to compare it performs exactly the traversal being forbidden. Walking
    # at most declared+1 cells answers the same question for the same inputs.
    if is_integer(declared) and declared > 0 and declared <= @max_manifest_pages and
         BoundedList.count_at_most(page_bytes, declared) == {:ok, declared},
       do: :ok,
       else: {:error, :page_bounds}
  end

  defp decode_pages(page_bytes) do
    # Prepend + reverse: linear, not quadratic.
    page_bytes
    |> Enum.reduce_while({:ok, []}, fn b, {:ok, acc} ->
      case WireDecode.decode_plan_page(b) do
        {:ok, page} -> {:cont, {:ok, [page | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  @doc """
  Fail-close one append-only assignment record on its own terms.

  TOTAL: any term is accepted and answered with a typed reason -- a validator whose
  contract promises `{:error, reason}` must not raise `KeyError` on a shape it did not
  expect.
  """
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(%SweepAssignmentRecordV1{} = r) do
    with :ok <- no_unknown_fields(r),
         :ok <- validate_identity(r),
         :ok <- validate_scope(r),
         :ok <- validate_lease(r),
         :ok <- validate_state(r) do
      validate_expectation(Map.get(r, :mtr_expectation))
    end
  end

  # A PLAIN MAP is refused, with the total fallback retained. Protobuf decoding always yields
  # the struct, so a map reached this by skipping the wire layer -- where retained unknown
  # fields and wire-hygiene violations live. A fully populated one used to validate, and then
  # carried straight through the composed grant boundary.
  def validate(_), do: {:error, :identity}

  @doc """
  Fail-close the assignment/plan RELATION, VALIDATING THE PLAN HERE and recomputing the
  expectation from committed plan data.
  """
  @spec validate_against_plan(term(), term(), term()) :: :ok | {:error, term()}
  def validate_against_plan(r, header, pages) do
    # NOTE: taking DECODED pages, this cannot establish the plan's WIRE hygiene --
    # protobuf-elixir erases an unknown group before this sees it. Callers holding raw
    # bytes should use validate_bytes_against_plan_bytes/3.
    #
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

    # The nested lookup is GUARDED: `mtr_expectation: 7` raised BadMapError here, which
    # is neither total nor fail-closed. A non-map expectation is a malformed shape and
    # is rejected outright by validate_expectation/1.
    nested =
      case Map.get(r, :mtr_expectation) do
        e when is_map(e) -> Map.get(e, :__unknown_fields__, [])
        _ -> []
      end

    # The SOURCE IDENTITY is a nested message too, and it was omitted: retained bytes inside it
    # sit outside every field-framed grammar that reads it, exactly like the expectation's.
    # Go's hasUnknownFields is recursive, so this walk has to reach the same places.
    source =
      case Map.get(r, :source_identity) do
        si when is_map(si) -> Map.get(si, :__unknown_fields__, [])
        _ -> []
      end

    if unknown == [] and nested == [] and source == [],
      do: :ok,
      else: {:error, :unknown_fields}
  end

  # The source identity is OPTIONAL -- its joint absence is a legal key shape -- but when
  # present EVERY member must be valid, or the key it builds is malformed. It must also be the
  # generated struct: a plain map skips the wire layer, and its retained unknown fields would
  # be invisible to the walk below.
  defp source_identity_valid?(nil), do: true

  defp source_identity_valid?(%EdgeSourceSpanIdentityV1{} = si) do
    Map.get(si, :kind) in @source_auth_kinds and
      uuid?(Map.get(si, :context_id)) and
      uuid?(Map.get(si, :source_scope_id)) and
      digest?(Map.get(si, :source_scope_sha256))
  end

  defp source_identity_valid?(_), do: false

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
    # PROTOBUF DOMAINS, not merely signs: 2^32 in a uint32 field and 2^64 in a
    # uint64 one are values the wire cannot represent, so accepting them describes
    # a message that cannot exist.
    # run_id is the PRODUCER's run identity and a REQUIRED mapping-key member. It is
    # deliberately NOT compared to execution_id: the spec makes them independent,
    # because resolving a span to an execution is what the mapping lookup does. An
    # all-zero value is not a canonical UUID, and without this rule Elixir accepted
    # one while Go rejected it -- a malformed key member reaching the grant boundary.
    # The carrier reference: id AND digest, both required.
    if uuid?(Map.get(r, :producer_assignment_id)) and uuid?(Map.get(r, :execution_id)) and
         PlanValidate.uuidv7?(Map.get(r, :execution_plan_id)) and
         uuid?(Map.get(r, :network_scope_id)) and
         uuid?(Map.get(r, :authenticated_agent_id)) and
         uuid?(Map.get(r, :production_scope_id)) and
         digest?(Map.get(r, :execution_plan_sha256)) and
         uint64?(Map.get(r, :record_sequence)) and Map.get(r, :record_sequence) > 0 and
         pos_int64?(Map.get(r, :authored_at_unix_nano)) and
         uint32?(Map.get(r, :execution_shard)) and
         uint64?(Map.get(r, :assignment_epoch)) and
         uuid?(Map.get(r, :run_id)) and
         PlanValidate.uuidv7?(Map.get(r, :compiled_assignment_id)) and
         digest?(Map.get(r, :compiled_assignment_sha256)) and
         source_identity_valid?(Map.get(r, :source_identity)) do
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
         uint64?(Map.get(r, :fence_token)) and Map.get(r, :fence_token) > 0 and
         pos_int64?(Map.get(r, :lease_expires_at_unix_nano)) do
      :ok
    else
      {:error, :lease}
    end
  end

  defp validate_state(r) do
    state = Map.get(r, :state)
    superseded = state == :SWEEP_ASSIGNMENT_STATE_SUPERSEDED
    link = Map.get(r, :superseded_by_assignment_id)

    cond do
      state not in @known_states ->
        {:error, :state}

      # superseded_by is present EXACTLY when the state is SUPERSEDED, and never names
      # the record itself -- that is a cycle, not a chain.
      superseded and not uuid?(link) ->
        {:error, :state}

      superseded and link == Map.get(r, :producer_assignment_id) ->
        {:error, :state}

      # A non-binary successor is MALFORMED, not absent: normalizing it to <<>> made a
      # bad shape pass, which is fail-open.
      not is_nil(link) and not is_binary(link) ->
        {:error, :state}

      not superseded and link not in [nil, <<>>] ->
        {:error, :state}

      not uint64?(Map.get(r, :terminal_batch_sequence)) ->
        {:error, :state}

      # An OPEN attempt has closed no evidence interval yet.
      state == :SWEEP_ASSIGNMENT_STATE_OPEN and Map.get(r, :terminal_batch_sequence) != 0 ->
        {:error, :state}

      true ->
        :ok
    end
  end

  # ABSENT is not ZERO. A record that never stated an expectation is rejected;
  # treating it as "expects nothing" turns a missing authority into a waiver.
  defp validate_expectation(nil), do: {:error, :expectation}

  # REQUIRES the generated struct, like the record and source identity around it. A plain map
  # skipped the wire layer, so its retained unknown fields are invisible to the walk above --
  # and a fully populated one validated here AND carried through the composed grant boundary.
  # The fallback below keeps this total.
  defp validate_expectation(%SweepMtrExpectationV1{} = e) do
    count = Map.get(e, :ordinal_count)
    commitment = Map.get(e, :ordinal_range_commitment)
    empty = commitment == <<0::256>>

    cond do
      not digest?(commitment) -> {:error, :expectation}
      # REQUIRED PRESENCE and a valid value: `plan_ordinal_offset: :bad` passed the
      # nil check and then compared unequal to any real offset, which is fail-open in a
      # standalone validation that never reaches the relation.
      not uint64?(Map.get(e, :plan_ordinal_offset)) -> {:error, :expectation}
      not uint64?(count) or count > @max_mtr_ordinals -> {:error, :expectation}
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
  defp uint32?(v), do: is_integer(v) and v >= 0 and v <= 0xFFFFFFFF
  defp uint64?(v), do: is_integer(v) and v >= 0 and v <= 0xFFFFFFFFFFFFFFFF
  defp pos_int64?(v), do: is_integer(v) and v > 0 and v <= 0x7FFFFFFFFFFFFFFF
  defp bounded_bytes?(v, min, :infinity), do: is_binary(v) and byte_size(v) >= min

  defp bounded_bytes?(v, min, max),
    do: is_binary(v) and byte_size(v) >= min and byte_size(v) <= max
end
