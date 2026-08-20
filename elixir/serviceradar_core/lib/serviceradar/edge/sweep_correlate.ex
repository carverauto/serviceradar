defmodule ServiceRadar.Edge.SweepCorrelate do
  @moduledoc """
  The Elixir peer of Go's `joinSweepAuthority` and the body-owned `source_run_id`
  disposition check: it binds a decoded `SweepObservationBatchV1` to the SIGNED
  SOURCE AUTHORITY carried by the ENCLOSING `EdgeRecordV1`.

  ## What this module is not

  It does NOT verify a signature and does NOT authorize collection. Those need key
  material and a trust resolver, and belong to the authenticated boundary. A caller
  reaching this module has already established that the capability it reads is
  authentic; this module only asks whether the BODY agrees with it.

  It is also not the full body validator. Shape, bounds and enum admission live in
  `SemanticValidate` / `WireValidate` and in the batch's own contract; what is
  frozen HERE is the correlation matrix — which authorization kind a source
  requires, which body field its signed context is compared against, and whether
  `source_run_id` may appear.

  ## Outcomes are (label, gate) PAIRS

  Every LABELLED rejection carries BOTH the portable label and the GATE that produced
  it. PRECONDITION failures are the deliberate exception: they carry no frozen label,
  because they are not a correlation verdict at all -- see `precondition_failure/0`.

  The labelled shapes:

      {:error, {:body, :source_run_id_disposition}}
      {:error, {:correlation, :context_id}}

  The pair is the unit because labels and gates are ORTHOGONAL. The disposition is
  decidable from the batch ALONE — `source` and `source_run_id` are fields of the
  same message and no signed authority is consulted — so it is BODY-owned, while
  every other label here compares a body field against a signed claim. Reporting
  the label without the gate lets a body rejection be read as a correlation one.

  This mirrors Go, where the same split is an unexported error carrying a label and
  the sentinel of its owning gate.

  ## Two rejections are deliberately UNLABELLED

  An unknown sweep `source` and the reserved recovery lane are refused by
  pre-existing gates with their own typed reasons. They surface as
  `{:error, {:enum_admission, :source}}` and `{:error, {:recovery_lane, :kind}}` —
  no frozen label, because none is frozen for them.
  """

  alias ServiceRadar.Edge.CapabilityClaims
  alias ServiceRadar.Edge.SweepBodyValidate
  alias ServiceRadar.Edge.SweepMatrix
  alias ServiceRadar.Edge.SweepOutcomePolicy
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1
  alias Serviceradar.Edge.V1.SweepHostObservationV1
  alias Serviceradar.Edge.V1.SweepMtrSummaryV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1
  alias ServiceRadar.Edge.WireDecode

  @typedoc "The gate that refused, paired with its reason."
  @type failure ::
          {:body, SweepMatrix.label()}
          | {:correlation, SweepMatrix.label()}
          | {:enum_admission, :source}
          | {:recovery_lane, :kind}

  @type outcome ::
          :ok
          | {:error, failure()}
          | {:error, precondition_failure()}

  @typedoc "Rejections raised before correlation is reached."
  @type payload_failure ::
          {:payload,
           :missing
           | :digest_missing
           | :digest_mismatch
           | :decode
           | :not_a_record
           | :compressed
           # The FRAMING FAMILY the record declared, when it is not the one this typed ingress
           # frames. It carries the offending value so a reject audit can name it.
           | {:framing_family, atom() | integer()}}

  @typedoc """
  A shape this relation cannot read. It is a PRECONDITION failure, not a correlation
  verdict: the full body validator (task 1.2-c) is what should have refused it, and
  this relation refuses rather than coercing the value into a readable default.
  """
  @type precondition_failure :: {:precondition, :malformed_batch | :malformed_record}

  @typedoc """
  The COMPLETE result union. `validate/2` can return a payload failure -- it rejects a
  non-record argument -- so `outcome()` alone would understate what it returns.
  """
  @type result :: outcome() | {:error, payload_failure()}

  @typedoc """
  A full-body-validator rejection that is NOT one of the two frozen outcomes below.

  Its own gate, deliberately. `{:body, label}` is frozen to carry a `SweepMatrix.label()`,
  so routing arbitrary body families through it would break that invariant for every
  existing caller; and these rejections are body-owned, so `:correlation` would misattribute
  them. This is the ONE gate task 1.2-c adds to the union.
  """
  @type body_validation_failure :: {:body_validation, {atom(), atom()}}

  @typedoc "The union once the full body validator is routed in (task 1.2-c step 3)."
  @type combined_result :: result() | {:error, body_validation_failure()}

  @doc """
  Translates a `SweepBodyValidate` reason into this module's union. Settled BEFORE step 3
  wires the call, because the mapping is a contract, not an implementation detail.

  TWO families are TRANSLATED, not passed through, because this module already froze an
  outcome for the same rejection and a caller matching on it must keep working:

      {:source_run_id, label}  ->  {:body, label}            (the frozen disposition outcome)
      {:source, :unknown}      ->  {:enum_admission, :source} (the frozen enum-admission one)

  Both are the SAME rule decided in both places -- the disposition is a function of two
  fields of the batch, and source admission is `SweepMatrix`'s -- so they must not surface
  under two different shapes depending on which validator ran.

  EVERY OTHER family enters under `:body_validation`, including `:shape` and `:width`, which
  have no Go peer. The mapping is TOTAL over the family set: a family added to the validator
  without a decision here fails `SweepCorrelateTest`, rather than silently arriving as an
  unmatched shape.
  """
  @spec translate_body_reason({atom(), atom()}) ::
          {:error, failure() | body_validation_failure()}
  def translate_body_reason({:source_run_id, label}), do: {:error, {:body, label}}
  def translate_body_reason({:source, :unknown}), do: {:error, {:enum_admission, :source}}

  def translate_body_reason({family, detail}) when is_atom(family) and is_atom(detail),
    do: {:error, {:body_validation, {family, detail}}}

  # Validate the body-decidable half: the `source_run_id` disposition.
  #
  # Separate from `correlate/2` because it consults NO signed authority. Deferring a
  # body-decidable rule past the body validator would carry a malformed batch into
  # authority comparison, where which mismatch is reported depends on which is
  # noticed first.
  @spec validate_body(term()) :: outcome()
  defp validate_body(%{source: source} = batch) do
    case SweepMatrix.fetch(source) do
      :error ->
        {:error, {:enum_admission, :source}}

      {:ok, row} ->
        case SweepMatrix.check_source_run_id(row, Map.get(batch, :source_run_id)) do
          :ok -> :ok
          {:error, label} -> {:error, {:body, label}}
        end
    end
  end

  defp validate_body(_), do: {:error, {:enum_admission, :source}}

  # Bind the batch to the enclosing record's signed source authority.
  #
  # The record is passed WHOLE, not just its claims: the presence of
  # `source_authorization` is itself one of the frozen relations, and a caller that
  # unwrapped the claims first would have already decided it.
  @spec correlate(term(), term()) :: outcome()
  defp correlate(record, %{source: source} = batch) do
    with {:ok, row} <- fetch_row(source),
         :ok <- recovery_lane(record),
         {:ok, claims} <- source_claims(record, row),
         :ok <- context(claims, row, batch),
         :ok <- range_identity(claims, batch),
         :ok <- digests(claims, batch),
         :ok <- producer(record, batch) do
      times(claims, batch)
    end
  end

  defp correlate(_record, _batch), do: {:error, {:enum_admission, :source}}

  @doc """
  Correlate the batch carried in `record.payload` against that record's authority.

  ## THIS IS NOT AN AUTHENTICATED BOUNDARY, and must not be used as one

  It performs NO signature verification, NO whole-record validation, NO
  outer-versus-signed mirror check, NO semantic-envelope check, NO contract
  dispatch, NO decompression, and NOT the full sweep body validator. A record whose
  source capability carries an EMPTY SIGNATURE passes this function.

  Its only advantage over `validate/2` is that the batch demonstrably comes from
  THIS record's payload rather than being supplied alongside it. That closes a
  substitution hole in the relation; it does not make the relation authoritative.

  ## Preconditions the CALLER must have established

    1. the record passed whole-record validation, including its semantic envelope;
    2. its capabilities were signature-verified against resolved trust;
    3. the outer `source_authorization` mirrors agree with the signed claims;
    4. contract dispatch accepted the record's output contract;
    5. the record declares `EDGE_RECORD_COMPRESSION_NONE`. This function does NOT
       accept a decompressed payload -- it reads `record.payload` -- so a compressed
       record is REFUSED with `{:payload, :compressed}` rather than assumed
       pre-decompressed. UNSPECIFIED is refused too: the proto default is not a
       declaration of NONE;
    6. the decoded batch passed the full body validator.

  Go composes all of that in `ValidateSweepRecord`, which is why its equivalent of
  this relation is UNEXPORTED. Elixir has no trust resolver here — the same carve-out
  the carrier and grant peers make — so this stays a RELATION with stated
  preconditions rather than pretending to be the boundary.

  DECODING HERE IS THE GENERATED DECODER, which RETAINS unknown fields and applies no
  work ceiling. This function does not call the curated one, because precondition 6
  says the body validator already ran that path over THESE EXACT BYTES.

  CALLERS HOLDING RAW PAYLOAD BYTES SHOULD USE `ingest_own_payload/1`, which composes
  the curated decode and the full body validator with this correlation. Reaching for
  the curated decoder alone is not enough either -- decoding is not validating, and a
  decoded batch still has to pass `SweepBodyValidate`. Use THIS function only when
  those exact bytes have already been through both.
  """
  @spec correlate_own_payload(term()) :: result()
  def correlate_own_payload(%EdgeRecordV1{} = record) do
    with :ok <- framing_family(record),
         :ok <- uncompressed(record),
         {:ok, payload} <- payload_bytes(record),
         :ok <- payload_digest(record, payload),
         {:ok, batch} <- decode_batch(payload) do
      validate(record, batch)
    end
  end

  def correlate_own_payload(_), do: {:error, {:payload, :not_a_record}}

  @doc """
  THE COMPOSED INGRESS (task 1.2-c step 3): extracted payload -> curated decode -> FULL body
  validation -> correlation, from ONE call.

  This is what `correlate_own_payload/1` could not be. That function decodes with the
  generated decoder and assumes precondition 6 -- that someone already ran the body
  validator -- so a body defect and a correlation defect reached callers from two different
  places, and nothing made the first actually run. Here they come from one ingress, and the
  body stage is `SweepBodyValidate.validate_bytes/1`, which carries the extracted-body work
  ceiling, recursive wire hygiene and unknown-field rejection that the generated decoder does
  not.

  Preconditions 1-5 of `correlate_own_payload/1` still apply: this is STILL NOT an
  authenticated boundary. It verifies no signature and resolves no trust.

  ## Outcomes

  Body reasons arrive through `translate_body_reason/1`, so the two rules decided in BOTH
  validators keep their frozen shapes -- `{:body, label}` and `{:enum_admission, :source}` --
  and everything else enters under `{:body_validation, {family, detail}}`.

  DECODER reasons get their own gate, `{:wire, reason}`, rather than being folded into the
  existing `{:payload, :decode}`. The curated decoder deliberately separates `:poison` from
  `:not_ready` and `:systemic` -- malformed data is not an undeployed schema is not a caller
  fault -- and collapsing them would discard the one classification that stage exists to make.
  """
  @spec ingest_own_payload(term()) :: combined_result() | {:error, {:wire, WireDecode.reason()}}
  def ingest_own_payload(%EdgeRecordV1{} = record) do
    with :ok <- framing_family(record),
         :ok <- uncompressed(record),
         {:ok, payload} <- payload_bytes(record),
         :ok <- payload_digest(record, payload),
         {:ok, batch} <- validated_body(payload) do
      # `correlate/2`, not `validate/2`: the disposition is body-decidable and the body
      # validator has already decided it, under the same frozen label. Running it twice
      # would be harmless but would state the rule in two places on one path.
      correlate(record, batch)
    end
  end

  def ingest_own_payload(_), do: {:error, {:payload, :not_a_record}}

  defp validated_body(payload) do
    case SweepBodyValidate.validate_bytes(payload) do
      {:ok, batch} -> {:ok, batch}
      {:error, reason} when is_atom(reason) -> {:error, {:wire, reason}}
      {:error, {_family, _detail} = reason} -> translate_body_reason(reason)
    end
  end

  @doc """
  Body-decidable rules FIRST, then correlation.

  THE ORDER IS NOT IDENTICAL TO GO'S. Go runs the reserved recovery lane during
  whole-record validation, BEFORE the body validator; here the disposition is
  checked first, because this module has no whole-record stage to hang the lane
  check on. Both refuse the same records; only which rejection surfaces first
  differs, and a shared vector asserting an exact reason must account for it.

  This arity takes the record and batch INDEPENDENTLY and cannot prove the batch came
  from that record's payload.

  PREFER `ingest_own_payload/1`: it binds the batch to the record's payload AND runs
  the full body validator, which neither this arity nor `correlate_own_payload/1`
  does. Use `correlate_own_payload/1` only when the payload bytes have already been
  validated. NONE of the three is an authenticated boundary -- read the preconditions
  on `correlate_own_payload/1`, which apply to all of them.
  """
  @spec validate(term(), term()) :: result()
  def validate(%EdgeRecordV1{} = record, %SweepObservationBatchV1{} = batch) do
    case validate_body(batch) do
      :ok -> correlate(record, batch)
      {:error, _} = err -> err
    end
  end

  def validate(_record, _batch), do: {:error, {:payload, :not_a_record}}

  # THE FAMILY <-> TYPED ENTRY POINT INVARIANT. `payload_family` is an immutable FRAMING and
  # LIFECYCLE discriminator: it does not select a contract -- the exact output contract selects
  # the semantic validator and projector, and there is deliberately no registry-wide
  # contract-to-family table -- and it is not authorization.
  #
  # It is checked HERE, at the typed boundary, because protobuf bytes are not intrinsically
  # type-tagged: this function decodes the payload as a SweepObservationBatchV1 regardless of
  # what the record claims, so a record declaring SNAPSHOT_PAGE_V1 would otherwise be ingested
  # carrying contradictory metadata, and every later reader that picks a decoder from the family
  # would be choosing from a value nothing validated.
  #
  # FIRST in the `with`, before decompression and digest: the record is misrouted whatever its
  # bytes turn out to be, and checking cheap framing before expensive decoding is also the order
  # Go uses.
  defp framing_family(record) do
    case Map.get(record, :payload_family) do
      :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1 ->
        :ok

      other when is_atom(other) or is_integer(other) ->
        {:error, {:payload, {:framing_family, other}}}

      # A generated struct is a MAP, so a hand-built one can hold ANY term here -- these
      # functions accept `term()` and must stay total. That is a shape this relation cannot
      # read, which is the existing `:malformed_record` PRECONDITION, not a framing verdict.
      #
      # Classifying it beats widening the framing tuple to `term()`: the tuple would then
      # promise less about what it carries, and a caller could no longer rely on it naming an
      # enum value. A retained unknown enum is an integer and a declared one is an atom, so
      # those two cases are exactly the reachable ones from real bytes.
      _ ->
        {:error, {:precondition, :malformed_record}}
    end
  end

  # UNCOMPRESSED ONLY, and refused rather than mis-decoded otherwise.
  #
  # This relation reads `record.payload` directly, so a ZSTD record's bytes are the
  # COMPRESSED ones and the decode would fail on valid input. It takes no decompressed
  # value, so it cannot honour a "caller already decompressed" precondition -- there is
  # nowhere to hand the result in. Until an extraction and decompression boundary
  # exists in this runtime to feed it, the honest contract accepts only
  # EDGE_RECORD_COMPRESSION_NONE.
  defp uncompressed(record) do
    case Map.get(record, :compression) do
      :EDGE_RECORD_COMPRESSION_NONE -> :ok
      # UNSPECIFIED is the proto default and is NOT an accepted declaration: a record
      # must say NONE, not leave the field unset.
      _ -> {:error, {:payload, :compressed}}
    end
  end

  defp payload_bytes(record) do
    case Map.get(record, :payload) do
      p when is_binary(p) and byte_size(p) > 0 -> {:ok, p}
      _ -> {:error, {:payload, :missing}}
    end
  end

  defp payload_digest(record, payload) do
    case Map.get(record, :payload_sha256) do
      d when is_binary(d) and byte_size(d) == 32 ->
        if :crypto.hash(:sha256, payload) == d,
          do: :ok,
          else: {:error, {:payload, :digest_mismatch}}

      _ ->
        {:error, {:payload, :digest_missing}}
    end
  end

  defp decode_batch(payload) do
    case SweepObservationBatchV1.decode(payload) do
      %SweepObservationBatchV1{} = b -> {:ok, b}
      _ -> {:error, {:payload, :decode}}
    end
  rescue
    _ -> {:error, {:payload, :decode}}
  end

  # --- frozen relations -----------------------------------------------------

  defp fetch_row(source) do
    case SweepMatrix.fetch(source) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, {:enum_admission, :source}}
    end
  end

  # RECOVERY_CONTROL on a sweep record is refused by the reserved lane, BEFORE the
  # correlation. It and INTEGRATION_RUN are both outside the mapping's range, but
  # they are NOT a matching pair: only INTEGRATION_RUN reaches correlation.
  # STRUCTURE FIRST. Reading the kind off any shape would let a malformed
  # authorization that happens to carry RECOVERY_CONTROL be reported as a lane
  # rejection instead of the structural failure it is.
  defp recovery_lane(%EdgeRecordV1{source_authorization: nil}), do: :ok

  defp recovery_lane(%EdgeRecordV1{source_authorization: %EdgeSourceAuthorizationV1{} = sa}) do
    # The NESTED shapes are preflighted too. An exact authorization struct can still hold a
    # malformed capability or claim body, and reading `kind` off it would report a lane
    # rejection for a record that is structurally unusable.
    #
    # This uses the STRUCTURAL extractor, not `source_claims_of/1`. The latter maps an exact
    # envelope carrying a DIFFERENT generated claim variant to `{:correlation, :source_kind}`
    # -- a matrix label. Minting one here, before the reserved-lane gate and on a record that
    # violates this module's documented preconditions, would report a correlation verdict for
    # something correlation never judged.
    case structural_source_claims(sa.capability) do
      :ok -> lane_kind(sa.kind)
      {:error, _} = err -> err
    end
  end

  defp recovery_lane(_), do: {:error, {:precondition, :malformed_record}}

  defp lane_kind(:EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL),
    do: {:error, {:recovery_lane, :kind}}

  defp lane_kind(_), do: :ok

  defp source_claims(record, row) do
    case Map.get(record, :source_authorization) do
      %EdgeSourceAuthorizationV1{} = sa ->
        source_authorization(sa, row)

      nil ->
        # GENUINELY ABSENT. The field is OPTIONAL at the record level, so no structural
        # gate can require it, and this correlation is the first thing that asks. This
        # is the only case the frozen `source_authority_absent` label describes.
        {:error, {:correlation, :source_authority_absent}}

      _present_but_not_the_generated_struct ->
        # PRESENT and unusable is not ABSENT. Reporting it under the frozen label
        # would claim an optional field was omitted when it was supplied malformed --
        # a structural failure the body validator (1.2-c) owns.
        {:error, {:precondition, :malformed_record}}
    end
  end

  defp source_authorization(sa, row) do
    if sa.kind == row.kind do
      source_claims_of(sa.capability)
    else
      {:error, {:correlation, :source_kind}}
    end
  end

  # STRUCTURE ONLY: is this the generated envelope, and is its claims oneof a generated
  # claim body? It makes no judgement about WHICH variant -- that is correlation's, later.
  # The EXACT tag/body pairs come from `CapabilityClaims`, the one structural predicate this
  # and capability signing share; it is pinned against the generated oneof metadata there.
  defp structural_source_claims(%EdgeSignedCapabilityV1{claims: claims}) do
    if CapabilityClaims.typed?(claims),
      do: :ok,
      else: {:error, {:precondition, :malformed_record}}
  end

  defp structural_source_claims(_), do: {:error, {:precondition, :malformed_record}}

  # The claims live in the generated ONEOF: `claims == {:source, %EdgeSourceClaimsV1{}}`.
  # There is no `:source` key on the capability struct, so the patterns below match the
  # oneof exactly and the fallbacks are TOTAL rather than defaulting to an empty binary.
  defp source_claims_of(%EdgeSignedCapabilityV1{
         claims: {:source, %EdgeSourceClaimsV1{} = claims}
       }), do: {:ok, claims}

  # The tag SAYS source but the body is not the generated claims struct: structurally
  # unusable. NOT :source_kind -- the kind IS source -- and NOT
  # :source_authority_absent, which describes a genuinely omitted optional field.
  defp source_claims_of(%EdgeSignedCapabilityV1{claims: {:source, _}}),
    do: {:error, {:precondition, :malformed_record}}

  # A genuinely DIFFERENT claims variant is a kind mismatch.
  defp source_claims_of(%EdgeSignedCapabilityV1{claims: {_other, _}}),
    do: {:error, {:correlation, :source_kind}}

  # Anything that is not the generated capability envelope -- including a plain map
  # with the right keys -- is structurally unusable rather than absent.
  defp source_claims_of(_), do: {:error, {:precondition, :malformed_record}}

  # The signed context is compared against the ONE operand this source selects.
  defp context(claims, row, batch) do
    if bin(claims, :context_id) == SweepMatrix.context_operand(row, Map.from_struct(batch)) do
      :ok
    else
      {:error, {:correlation, :context_id}}
    end
  end

  # Two labels, so two checks: the signed claim carries scope_sha256 AND
  # target_range_sha256, and one combined branch would let either be deleted.
  defp range_identity(claims, batch) do
    cond do
      bin(claims, :scope_id) != bin(batch, :target_range_id) ->
        {:error, {:correlation, :range_id}}

      bin(claims, :scope_sha256) != bin(batch, :target_range_sha256) ->
        {:error, {:correlation, :scope_digest}}

      true ->
        :ok
    end
  end

  defp digests(claims, batch) do
    cond do
      bin(claims, :target_range_sha256) != bin(batch, :target_range_sha256) ->
        {:error, {:correlation, :target_range_digest}}

      bin(claims, :execution_plan_sha256) != bin(batch, :execution_plan_sha256) ->
        {:error, {:correlation, :plan_digest}}

      true ->
        :ok
    end
  end

  defp producer(record, batch) do
    p = Map.get(record, :producer_context)

    cond do
      # EXACT generated struct: a plain map with the right keys is still not what a
      # decoded record carries, and accepting one would let a fabricated shape pass.
      not match?(%EdgeProducerContext{}, p) ->
        {:error, {:precondition, :malformed_record}}

      Map.get(batch, :execution_shard) != Map.get(p, :run_shard) ->
        {:error, {:correlation, :execution_shard}}

      Map.get(batch, :assignment_epoch) != (Map.get(p, :authority_epoch) || 0) ->
        {:error, {:correlation, :assignment_epoch}}

      true ->
        :ok
    end
  end

  # The collection window is INCLUSIVE at both endpoints. This is the
  # EdgeSourceClaimsV1 window; EdgeAssignmentExecutionClaimsV1 declares fields with
  # the same two names and they are HALF-OPEN.
  # The signed window is read ONCE, here. Validating it per path would leave the
  # host and trace `:malformed` branches UNREACHABLE -- batch_time consumes the same
  # two endpoints first -- so those branches would be dead code that no vector could
  # exercise. Resolving the bounds up front removes them instead of testing them.
  defp times(claims, batch) do
    with {:ok, window} <- window_bounds(claims),
         :ok <- batch_time(window, batch) do
      hosts(window, batch)
    end
  end

  defp window_bounds(claims) do
    with {:ok, lo} <- int(claims, :collection_not_before_unix_nano),
         {:ok, hi} <- int(claims, :collection_expires_unix_nano) do
      {:ok, {lo, hi}}
    else
      :malformed -> {:error, {:precondition, :malformed_record}}
    end
  end

  defp batch_time(window, batch) do
    case int(batch, :observed_at_unix_nano) do
      :malformed ->
        {:error, {:precondition, :malformed_batch}}

      {:ok, ns} ->
        if within?(ns, window), do: :ok, else: {:error, {:correlation, :batch_time_window}}
    end
  end

  defp hosts(window, batch) do
    case Map.get(batch, :hosts) do
      list when is_list(list) -> reduce_hosts(window, batch, list)
      _ -> {:error, {:precondition, :malformed_batch}}
    end
  end

  defp reduce_hosts(window, batch, list) do
    Enum.reduce_while(list, :ok, fn h, _ ->
      case host(window, batch, h) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp host(_window, _batch, h) when not is_struct(h, SweepHostObservationV1),
    do: {:error, {:precondition, :malformed_batch}}

  defp host(window, batch, h) do
    with {:ok, base} <- int(batch, :observed_at_unix_nano),
         {:ok, delta} <- int(h, :observed_at_delta_nano) do
      host_times(window, h, base, delta)
    else
      :malformed -> {:error, {:precondition, :malformed_batch}}
    end
  end

  defp host_times(window, h, base, delta) do
    # OVERFLOW and OUT-OF-WINDOW are separate labels, so separate checks: a wrapped
    # sum can land INSIDE the window, so folding them reports the wrong reason for
    # exactly the case that matters.
    case add_int64(base, delta) do
      :overflow ->
        {:error, {:correlation, :host_time_overflow}}

      {:ok, abs} ->
        if within?(abs, window),
          do: mtr(window, h),
          else: {:error, {:correlation, :host_time_window}}
    end
  end

  defp mtr(window, h) do
    case Map.get(h, :mtr) do
      nil ->
        :ok

      m when not is_struct(m, SweepMtrSummaryV1) ->
        {:error, {:precondition, :malformed_batch}}

      m ->
        if trace_allocated?(Map.get(m, :outcome)) do
          case uuid_v7_nanos(bin(m, :trace_id)) do
            :error ->
              {:error, {:correlation, :trace_time_overflow}}

            {:ok, ns} ->
              if within?(ns, window), do: :ok, else: {:error, {:correlation, :trace_time_window}}
          end
        else
          :ok
        end
    end
  end

  # --- primitives -----------------------------------------------------------

  @int64_max 0x7FFFFFFFFFFFFFFF
  @int64_min -0x8000000000000000
  @nanos_per_milli 1_000_000
  @max_uuid_v7_millis div(@int64_max, @nanos_per_milli)

  # The window is ALREADY RESOLVED by window_bounds/1, so a malformed endpoint is a
  # precondition failure raised once, before any path runs -- never a
  # `batch_time_window` correlation verdict. INCLUSIVE at both ends.
  defp within?(ns, {lo, hi}) when is_integer(ns), do: ns >= lo and ns <= hi
  defp within?(_ns, _window), do: false

  # Numeric reads REFUSE rather than substitute. Coercing a malformed value to 0 is
  # FAIL-OPEN: it invents a time the record never carried, and can turn a structurally
  # invalid batch into `:ok`.
  defp int(m, key) when is_map(m) do
    case Map.get(m, key) do
      v when is_integer(v) -> {:ok, v}
      _ -> :malformed
    end
  end

  defp int(_, _), do: :malformed

  defp add_int64(a, b) do
    sum = a + b
    if sum > @int64_max or sum < @int64_min, do: :overflow, else: {:ok, sum}
  end

  # The CHECKED millisecond-to-nanosecond conversion. RFC 9562 gives the timestamp
  # 48 bits; int64 nanos top out near 9_223_372_036_854 ms, so most of the encodable
  # range overflows and an unchecked multiply wraps a far-future identity INTO the
  # window it should have been refused by.
  defp uuid_v7_nanos(<<ms::48, _rest::80>>) when ms <= @max_uuid_v7_millis,
    do: {:ok, ms * @nanos_per_milli}

  defp uuid_v7_nanos(_), do: :error

  # The trace-allocation policy lives in `SweepOutcomePolicy`, which depends on neither this
  # module nor the body validator. Holding it here would make the body validator depend on
  # the correlation module, and step 3 routes the body validator INTO this one -- a mutual
  # edge, and not the one-way edge the ledger records.
  @doc false
  defdelegate trace_allocating_outcomes(), to: SweepOutcomePolicy

  defp trace_allocated?(o), do: SweepOutcomePolicy.trace_allocated?(o)

  defp bin(nil, _key), do: <<>>
  defp bin(m, key), do: Map.get(m, key) || <<>>
end
