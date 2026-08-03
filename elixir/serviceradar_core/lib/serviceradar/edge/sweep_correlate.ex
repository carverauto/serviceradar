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

  alias ServiceRadar.Edge.SweepMatrix
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias Serviceradar.Edge.V1.SweepHostObservationV1
  alias Serviceradar.Edge.V1.SweepMtrSummaryV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1

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
          | {:error, precondition_failure()}

  @typedoc "Rejections raised before correlation is reached."
  @type payload_failure ::
          {:payload,
           :missing | :digest_missing | :digest_mismatch | :decode | :not_a_record | :compressed}

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

  DECODING IS THE GENERATED DECODER, not `WireDecode`: there is no curated sweep
  decoder yet, so the `:poison` / `:not_ready` classification, the received-byte
  ceiling, recursive wire hygiene and unknown-field rejection are all ABSENT. Those
  belong to the body validator this relation assumes has already run.
  """
  @spec correlate_own_payload(term()) :: result()
  def correlate_own_payload(%EdgeRecordV1{} = record) do
    with :ok <- uncompressed(record),
         {:ok, payload} <- payload_bytes(record),
         :ok <- payload_digest(record, payload),
         {:ok, batch} <- decode_batch(payload) do
      validate(record, batch)
    end
  end

  def correlate_own_payload(_), do: {:error, {:payload, :not_a_record}}

  @doc """
  Body-decidable rules FIRST, then correlation.

  THE ORDER IS NOT IDENTICAL TO GO'S. Go runs the reserved recovery lane during
  whole-record validation, BEFORE the body validator; here the disposition is
  checked first, because this module has no whole-record stage to hang the lane
  check on. Both refuse the same records; only which rejection surfaces first
  differs, and a shared vector asserting an exact reason must account for it.

  This arity takes the record and batch INDEPENDENTLY and cannot prove the batch
  came from that record's payload. Prefer `correlate_own_payload/1`, and read its
  preconditions — neither function is an authenticated boundary.
  """
  @spec validate(term(), term()) :: result()
  def validate(%EdgeRecordV1{} = record, %SweepObservationBatchV1{} = batch) do
    case validate_body(batch) do
      :ok -> correlate(record, batch)
      {:error, _} = err -> err
    end
  end

  def validate(_record, _batch), do: {:error, {:payload, :not_a_record}}

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
  defp recovery_lane(record) do
    case get_in_struct(record, [:source_authorization, :kind]) do
      :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL -> {:error, {:recovery_lane, :kind}}
      _ -> :ok
    end
  end

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

  # The claims live in the generated ONEOF: `claims == {:source, %EdgeSourceClaimsV1{}}`.
  # There is no `:source` key on the capability struct, so the patterns below match the
  # oneof exactly and the fallbacks are TOTAL rather than defaulting to an empty binary.
  defp source_claims_of(%EdgeSignedCapabilityV1{
         claims: {:source, %Serviceradar.Edge.V1.EdgeSourceClaimsV1{} = claims}
       }),
       do: {:ok, claims}

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
  defp times(claims, batch) do
    with :ok <- batch_time(claims, batch) do
      hosts(claims, batch)
    end
  end

  defp batch_time(claims, batch) do
    case int(batch, :observed_at_unix_nano) do
      :malformed ->
        {:error, {:precondition, :malformed_batch}}

      {:ok, ns} ->
        case within?(ns, claims) do
          {:ok, true} -> :ok
          {:ok, false} -> {:error, {:correlation, :batch_time_window}}
          :malformed -> {:error, {:precondition, :malformed_record}}
        end
    end
  end

  defp hosts(claims, batch) do
    case Map.get(batch, :hosts) do
      list when is_list(list) -> reduce_hosts(claims, batch, list)
      _ -> {:error, {:precondition, :malformed_batch}}
    end
  end

  defp reduce_hosts(claims, batch, list) do
    Enum.reduce_while(list, :ok, fn h, _ ->
      case host(claims, batch, h) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp host(_claims, _batch, h) when not is_struct(h, SweepHostObservationV1),
    do: {:error, {:precondition, :malformed_batch}}

  defp host(claims, batch, h) do
    with {:ok, base} <- int(batch, :observed_at_unix_nano),
         {:ok, delta} <- int(h, :observed_at_delta_nano) do
      host_times(claims, h, base, delta)
    else
      :malformed -> {:error, {:precondition, :malformed_batch}}
    end
  end

  defp host_times(claims, h, base, delta) do
    # OVERFLOW and OUT-OF-WINDOW are separate labels, so separate checks: a wrapped
    # sum can land INSIDE the window, so folding them reports the wrong reason for
    # exactly the case that matters.
    case add_int64(base, delta) do
      :overflow ->
        {:error, {:correlation, :host_time_overflow}}

      {:ok, abs} ->
        case within?(abs, claims) do
          {:ok, true} -> mtr(claims, h)
          {:ok, false} -> {:error, {:correlation, :host_time_window}}
          :malformed -> {:error, {:precondition, :malformed_record}}
        end
    end
  end

  defp mtr(claims, h) do
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
              case within?(ns, claims) do
                {:ok, true} -> :ok
                {:ok, false} -> {:error, {:correlation, :trace_time_window}}
                :malformed -> {:error, {:precondition, :malformed_record}}
              end
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

  # Returns {:ok, boolean} or :malformed. Collapsing :malformed to `false` would turn
  # a malformed SIGNED WINDOW ENDPOINT into a genuine `batch_time_window` correlation
  # verdict -- a precondition failure reported as a contract violation.
  defp within?(ns, claims) when is_integer(ns) do
    with {:ok, lo} <- int(claims, :collection_not_before_unix_nano),
         {:ok, hi} <- int(claims, :collection_expires_unix_nano) do
      {:ok, ns >= lo and ns <= hi}
    end
  end

  defp within?(_ns, _claims), do: :malformed

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

  # EXACTLY Go's `mtrOutcomeAllocated`. These four outcomes allocate a trace id, and
  # only those four carry a trace time the signed window applies to.
  @trace_allocating [
    :MTR_OUTCOME_REACHED,
    :MTR_OUTCOME_TARGET_UNREACHABLE,
    :MTR_OUTCOME_PROBE_FAILED,
    :MTR_OUTCOME_TIMED_OUT
  ]

  @doc false
  def trace_allocating_outcomes, do: @trace_allocating

  defp trace_allocated?(o), do: o in @trace_allocating

  defp bin(nil, _key), do: <<>>
  defp bin(m, key), do: Map.get(m, key) || <<>>

  defp get_in_struct(nil, _path), do: nil
  defp get_in_struct(m, []), do: m

  defp get_in_struct(m, [k | rest]) when is_map(m), do: get_in_struct(Map.get(m, k), rest)
  defp get_in_struct(_, _), do: nil
end
