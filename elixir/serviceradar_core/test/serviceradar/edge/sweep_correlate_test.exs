defmodule ServiceRadar.Edge.SweepCorrelateTest do
  @moduledoc """
  The Elixir half of the sweep correlation proof, peering Go's
  `TestSweepJoinLabelsAreDistinctPerPredicate` and the disposition suite.

  EVERY LABELLED ASSERTION PINS THE (LABEL, GATE) PAIR. Precondition failures are the
  exception and carry no frozen label: they are structural refusals, not correlation
  verdicts. Asserting them separately — the label
  in one test, the gate in another — leaves the pair unpinned: a site can emit the
  right label from the wrong gate, or the reverse, and both tests stay green. The
  outcome tuple carries both, so they cannot be split here.

  Each negative differs from the control in ONE relation, so it proves the rule it
  is named after rather than whichever check runs first.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SweepCorrelate
  alias Serviceradar.Edge.V1, as: V1

  @window_start 1_700_000_000_000_000_000
  @window_end 1_700_000_600_000_000_000
  @observed 1_700_000_300_000_000_000

  # A CANONICAL UUID: 16 bytes, version nibble in 1..8, RFC variant-10 bits. A bare
  # <<seed, 0...>> is 16 bytes but NOT canonical, so the disposition check refuses it
  # and every correlation assertion below would fail for the wrong reason.
  defp u(seed), do: <<seed::8, 0::40, 7::4, 0::12, 0b10::2, 0::62>>
  defp d32(seed), do: :binary.copy(<<seed>>, 32)

  # A UUIDv7 carrying an exact millisecond timestamp.
  defp uuid_at(ms), do: <<ms::48, 7::4, 0::12, 0b10::2, 0::62>>

  # CONTROL: correlates cleanly. Every negative below mutates exactly one thing.
  # SCHEDULED_CHECK selects source_run_id, and execution_id is DELIBERATELY
  # different — were they equal the control would pass under either operand rule
  # and prove nothing about which was selected.
  # REAL GENERATED STRUCTS, not fabricated maps. A hand-built map can carry keys the
  # generated struct does not have -- the claims live in the ONEOF, as
  # `claims: {:source, %EdgeSourceClaimsV1{}}` -- so only generated structs prove the
  # module reads what a decoded record actually carries.
  defp claims_struct do
    %V1.EdgeSourceClaimsV1{
      kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
      context_id: u(0x23),
      scope_id: u(0x22),
      scope_sha256: d32(0xAA),
      target_range_sha256: d32(0xAA),
      execution_plan_sha256: d32(0xBB),
      collection_not_before_unix_nano: @window_start,
      collection_expires_unix_nano: @window_end
    }
  end

  defp control do
    batch = %V1.SweepObservationBatchV1{
      source: :SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
      execution_id: u(0x20),
      source_run_id: u(0x23),
      target_range_id: u(0x22),
      target_range_sha256: d32(0xAA),
      execution_plan_sha256: d32(0xBB),
      execution_shard: 3,
      assignment_epoch: 5,
      observed_at_unix_nano: @observed,
      hosts: []
    }

    c = claims_struct()

    record = %V1.EdgeRecordV1{
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      # The FRAMING FAMILY this ingress accepts. Omitting it left the control at UNSPECIFIED --
      # a value no real sweep record carries -- which is the same defect the comment below names
      # for the outer mirrors: a control must be a record an authenticated boundary would admit.
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
      source_authorization: %V1.EdgeSourceAuthorizationV1{
        kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
        # The OUTER mirrors agree with the signed claims. This relation does not read
        # them, but a control that leaves them empty is not a record any authenticated
        # boundary would admit, and the shared corpus must be built from records that
        # ARE admissible.
        context_id: c.context_id,
        scope_id: c.scope_id,
        scope_sha256: c.scope_sha256,
        capability: %V1.EdgeSignedCapabilityV1{claims: {:source, c}}
      },
      producer_context: %V1.EdgeProducerContext{run_shard: 3, authority_epoch: 5}
    }

    {record, batch}
  end

  # Replace the signed source claims, keeping the ONEOF wrapper intact.
  defp put_claims(record, fun) do
    {:source, c} = record.source_authorization.capability.claims
    cap = %{record.source_authorization.capability | claims: {:source, fun.(c)}}
    sa = %{record.source_authorization | capability: cap}
    %{record | source_authorization: sa}
  end

  test "the control correlates, so every negative below measures one change" do
    {record, batch} = control()
    assert SweepCorrelate.validate(record, batch) == :ok
  end

  describe "correlation-gated labels" do
    test "absent source authority" do
      {record, batch} = control()
      record = %{record | source_authorization: nil}

      assert SweepCorrelate.validate(record, batch) ==
               {:error, {:correlation, :source_authority_absent}}
    end

    test "wrong kind" do
      {record, batch} = control()
      sa = %{record.source_authorization | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC}

      assert SweepCorrelate.validate(%{record | source_authorization: sa}, batch) ==
               {:error, {:correlation, :source_kind}}
    end

    test "context id — the SELECTED operand, not the other field" do
      {record, batch} = control()
      # Point the signed context at execution_id, which THIS row does not select.
      record = put_claims(record, &%{&1 | context_id: u(0x20)})

      assert SweepCorrelate.validate(record, batch) ==
               {:error, {:correlation, :context_id}}
    end

    test "range id" do
      {record, batch} = control()
      record = put_claims(record, &%{&1 | scope_id: u(0x7D)})

      assert SweepCorrelate.validate(record, batch) ==
               {:error, {:correlation, :range_id}}
    end

    test "scope digest and target-range digest are SEPARATE labels" do
      {record, batch} = control()

      r1 = put_claims(record, &%{&1 | scope_sha256: d32(0x7C)})

      assert SweepCorrelate.validate(r1, batch) ==
               {:error, {:correlation, :scope_digest}}

      r2 = put_claims(record, &%{&1 | target_range_sha256: d32(0x7B)})

      assert SweepCorrelate.validate(r2, batch) ==
               {:error, {:correlation, :target_range_digest}}
    end

    test "plan digest" do
      {record, batch} = control()

      record =
        put_claims(record, &%{&1 | execution_plan_sha256: d32(0x7A)})

      assert SweepCorrelate.validate(record, batch) ==
               {:error, {:correlation, :plan_digest}}
    end

    test "execution shard" do
      {record, batch} = control()

      assert SweepCorrelate.validate(record, %{batch | execution_shard: 99}) ==
               {:error, {:correlation, :execution_shard}}
    end

    test "assignment epoch" do
      {record, batch} = control()

      assert SweepCorrelate.validate(record, %{batch | assignment_epoch: 4242}) ==
               {:error, {:correlation, :assignment_epoch}}
    end
  end

  describe "time windows — both sides, all three paths" do
    test "batch time before start and after expiry" do
      {record, batch} = control()

      assert SweepCorrelate.validate(record, %{batch | observed_at_unix_nano: @window_start - 1}) ==
               {:error, {:correlation, :batch_time_window}}

      assert SweepCorrelate.validate(record, %{batch | observed_at_unix_nano: @window_end + 1}) ==
               {:error, {:correlation, :batch_time_window}}
    end

    test "both collection endpoints are INSIDE" do
      {record, batch} = control()

      assert SweepCorrelate.validate(record, %{batch | observed_at_unix_nano: @window_start}) ==
               :ok

      assert SweepCorrelate.validate(record, %{batch | observed_at_unix_nano: @window_end}) == :ok
    end

    test "host absolute time before start and after expiry" do
      {record, batch} = control()

      for delta <- [@window_start - @observed - 1, @window_end - @observed + 1] do
        b = %{batch | hosts: [%V1.SweepHostObservationV1{observed_at_delta_nano: delta}]}
        assert SweepCorrelate.validate(record, b) == {:error, {:correlation, :host_time_window}}
      end
    end

    test "host delta OVERFLOW is refused, not wrapped" do
      {record, batch} = control()

      b = %{
        batch
        | hosts: [%V1.SweepHostObservationV1{observed_at_delta_nano: 0x7FFF_FFFF_FFFF_FFFF}]
      }

      assert SweepCorrelate.validate(record, b) == {:error, {:correlation, :host_time_overflow}}
    end

    test "MTR trace identity time outside the window" do
      {record, batch} = control()
      outside = div(@window_end, 1_000_000) + 10

      host = %V1.SweepHostObservationV1{
        observed_at_delta_nano: 0,
        mtr: %V1.SweepMtrSummaryV1{outcome: :MTR_OUTCOME_REACHED, trace_id: uuid_at(outside)}
      }

      assert SweepCorrelate.validate(record, %{batch | hosts: [host]}) ==
               {:error, {:correlation, :trace_time_window}}
    end

    test "EVERY trace-allocating outcome is subject to the window, not just REACHED" do
      {record, batch} = control()
      outside = div(@window_end, 1_000_000) + 10

      # A LITERAL list, matching Go's `mtrOutcomeAllocated`. Iterating the module's own
      # `trace_allocating_outcomes/0` would shrink WITH it, so a set that lost entries
      # would still pass.
      for outcome <- [
            :MTR_OUTCOME_REACHED,
            :MTR_OUTCOME_TARGET_UNREACHABLE,
            :MTR_OUTCOME_PROBE_FAILED,
            :MTR_OUTCOME_TIMED_OUT
          ] do
        host = %V1.SweepHostObservationV1{
          observed_at_delta_nano: 0,
          mtr: %V1.SweepMtrSummaryV1{outcome: outcome, trace_id: uuid_at(outside)}
        }

        assert SweepCorrelate.validate(record, %{batch | hosts: [host]}) ==
                 {:error, {:correlation, :trace_time_window}},
               "#{outcome} escaped the window"
      end
    end

    test "the module's allocating set is EXACTLY those four" do
      # Pinned separately from the behavioural loop so a set change fails here by
      # name, rather than silently reducing that loop's coverage.
      assert MapSet.new(SweepCorrelate.trace_allocating_outcomes()) ==
               MapSet.new([
                 :MTR_OUTCOME_REACHED,
                 :MTR_OUTCOME_TARGET_UNREACHABLE,
                 :MTR_OUTCOME_PROBE_FAILED,
                 :MTR_OUTCOME_TIMED_OUT
               ])
    end

    test "a NON-allocating outcome carries no trace time to check" do
      {record, batch} = control()

      # Without this control the test above would pass on a peer that checked EVERY
      # outcome, which is a different rule.
      # NO trace id: a NOT_ADMITTED outcome carrying one is refused by the body
      # validator before correlation, so such a control would be invalid. With the id
      # EMPTY, an over-broad allocation predicate produces :trace_time_overflow --
      # which is exactly what makes this control able to fail.
      host = %V1.SweepHostObservationV1{
        observed_at_delta_nano: 0,
        mtr: %V1.SweepMtrSummaryV1{outcome: :MTR_OUTCOME_NOT_ADMITTED, trace_id: <<>>}
      }

      assert SweepCorrelate.validate(record, %{batch | hosts: [host]}) == :ok
    end

    test "a malformed SIGNED WINDOW ENDPOINT is a precondition failure, not a window verdict" do
      {record, batch} = control()

      # BOTH endpoints, independently: collapsing :malformed to `false` inside the
      # window check would report `batch_time_window`, i.e. a genuine correlation
      # verdict, for what is actually an unreadable signed claim.
      for field <- [:collection_not_before_unix_nano, :collection_expires_unix_nano] do
        r = put_claims(record, &Map.put(&1, field, :whenever))

        assert SweepCorrelate.validate(r, batch) == {:error, {:precondition, :malformed_record}},
               "#{field} was misclassified"
      end
    end

    test "a malformed endpoint is refused ONCE, before any time path runs" do
      {record, batch} = control()

      # The window is resolved ONCE, before batch/host/trace are checked, so there is no
      # per-path malformed branch to exercise. Asserting the host and trace paths here
      # would be vacuous: batch_time consumes the same two endpoints first, so such
      # assertions would pass without ever reaching the path they name.
      r = put_claims(record, &Map.put(&1, :collection_expires_unix_nano, :whenever))

      host_batch = %{batch | hosts: [%V1.SweepHostObservationV1{observed_at_delta_nano: 0}]}

      assert SweepCorrelate.validate(r, batch) == {:error, {:precondition, :malformed_record}}

      assert SweepCorrelate.validate(r, host_batch) ==
               {:error, {:precondition, :malformed_record}}
    end

    test "MTR trace UUIDv7 whose ms->ns conversion OVERFLOWS" do
      {record, batch} = control()
      # 18446744073710 ms is past the int64-ns bound, encodable in 48 bits, and its
      # UNCHECKED product wraps to a small positive value near the epoch — i.e. one
      # this window could plausibly contain. An overflow wrapping out of range would
      # be refused either way and prove nothing.
      host = %V1.SweepHostObservationV1{
        observed_at_delta_nano: 0,
        mtr: %V1.SweepMtrSummaryV1{
          outcome: :MTR_OUTCOME_REACHED,
          trace_id: uuid_at(18_446_744_073_710)
        }
      }

      assert SweepCorrelate.validate(record, %{batch | hosts: [host]}) ==
               {:error, {:correlation, :trace_time_overflow}}
    end
  end

  describe "body-gated and unlabelled rejections" do
    test "the disposition is BODY-gated, not correlation-gated" do
      {record, batch} = control()

      assert SweepCorrelate.validate(record, %{batch | source_run_id: nil}) ==
               {:error, {:body, :source_run_id_disposition}}

      forbidden = %{batch | source: :SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP}

      assert SweepCorrelate.validate(record, forbidden) ==
               {:error, {:body, :source_run_id_disposition}}
    end

    test "an unknown source is refused by ENUM ADMISSION, with no frozen label" do
      {record, batch} = control()

      assert SweepCorrelate.validate(record, %{
               batch
               | source: :SWEEP_EXECUTION_SOURCE_UNSPECIFIED
             }) ==
               {:error, {:enum_admission, :source}}
    end

    test "a MALFORMED authorization carrying RECOVERY_CONTROL is structural, not a lane hit" do
      {record, batch} = control()
      # Reading the kind off any shape would report a lane rejection for what is a
      # structural failure.
      plain = %{kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL}

      assert SweepCorrelate.validate(%{record | source_authorization: plain}, batch) ==
               {:error, {:precondition, :malformed_record}}
    end

    test "an EXACT recovery authorization with a malformed NESTED capability is structural" do
      {record, batch} = control()
      # The outer struct is exact and the kind IS RECOVERY_CONTROL, but the capability is
      # not the generated envelope. Reading the kind without preflighting the nested shape
      # would report a lane rejection for an unusable record.
      # The ENVELOPE is the only thing that varies: the claim body is the EXACT struct,
      # so this changes one axis rather than two.
      {:source, exact} = record.source_authorization.capability.claims

      sa = %{
        record.source_authorization
        | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
          capability: %{claims: {:source, exact}}
      }

      assert SweepCorrelate.validate(%{record | source_authorization: sa}, batch) ==
               {:error, {:precondition, :malformed_record}}

      # Same with an exact envelope but a plain-map claim BODY.
      {:source, c} = record.source_authorization.capability.claims

      sa2 = %{
        record.source_authorization
        | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
          capability: %V1.EdgeSignedCapabilityV1{claims: {:source, Map.from_struct(c)}}
      }

      assert SweepCorrelate.validate(%{record | source_authorization: sa2}, batch) ==
               {:error, {:precondition, :malformed_record}}
    end

    test "RECOVERY_CONTROL is refused by the RESERVED LANE, which runs first" do
      {record, batch} = control()
      # BOTH the outer mirror AND the signed claim carry RECOVERY_CONTROL. Changing only
      # the outer one leaves a record whose mirror disagrees with its claims, which no
      # authenticated boundary would admit -- so it would not be a valid lane control.
      r = put_claims(record, &%{&1 | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL})

      r = %{
        r
        | source_authorization: %{
            r.source_authorization
            | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL
          }
      }

      assert SweepCorrelate.validate(r, batch) == {:error, {:recovery_lane, :kind}}
    end

    test "the lane preflight rejects any struct, unknown tag, or mismatched pair" do
      {record, batch} = control()

      # `is_struct/1` alone would admit all three of these and let them reach the lane
      # gate as if well formed.
      for {name, claims} <- [
            {"arbitrary struct", {:source, %URI{}}},
            {"unknown tag", {:bogus_tag, %V1.EdgeSourceClaimsV1{}}},
            {"mismatched pair", {:source, %V1.EdgeProductionClaimsV1{}}}
          ] do
        sa = %{
          record.source_authorization
          | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
            capability: %V1.EdgeSignedCapabilityV1{claims: claims}
        }

        assert SweepCorrelate.validate(%{record | source_authorization: sa}, batch) ==
                 {:error, {:precondition, :malformed_record}},
               "#{name} was not refused"
      end
    end

    test "EVERY frozen claim variant is structurally accepted by the preflight" do
      # The variant SET is pinned against generated oneof metadata in
      # capability_claims_test.exs; asserting it again from a list written here would only
      # compare two handwritten lists. What this pins is that the preflight uses that
      # shared predicate -- every frozen pair must clear it, so the lane gate (not the
      # structural gate) is what answers.
      {record, batch} = control()

      for {tag, mod} <- ServiceRadar.Edge.CapabilityClaims.variants() do
        sa = %{
          record.source_authorization
          | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
            capability: %V1.EdgeSignedCapabilityV1{claims: {tag, struct(mod)}}
        }

        assert SweepCorrelate.validate(%{record | source_authorization: sa}, batch) ==
                 {:error, {:recovery_lane, :kind}},
               "#{inspect(tag)} was refused structurally instead of reaching the lane gate"
      end
    end

    test "the lane preflight does not mint a MATRIX label for a wrong claim variant" do
      {record, batch} = control()
      # An exact envelope carrying a DIFFERENT generated claim variant, with the lane kind
      # set. Correlation would call this `:source_kind`; the lane gate must not, because it
      # runs before correlation and this record violates the module's preconditions.
      cap = %V1.EdgeSignedCapabilityV1{claims: {:production, %V1.EdgeProductionClaimsV1{}}}

      sa = %{
        record.source_authorization
        | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
          capability: cap
      }

      assert SweepCorrelate.validate(%{record | source_authorization: sa}, batch) ==
               {:error, {:recovery_lane, :kind}}
    end

    test "INTEGRATION_RUN reaches CORRELATION — the two unreachable kinds differ" do
      {record, batch} = control()
      sa = %{record.source_authorization | kind: :EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN}

      assert SweepCorrelate.validate(%{record | source_authorization: sa}, batch) ==
               {:error, {:correlation, :source_kind}}
    end
  end

  describe "every operand row" do
    # The selected-context mismatch is constructed DIFFERENTLY per row: on the
    # forbidden rows the "other field" is source_run_id, which those rows forbid, so
    # pointing the context at it would break two rules and prove whichever runs
    # first.
    test "execution-id rows select execution_id" do
      {record, batch} = control()

      for source <- [
            :SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP,
            :SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE
          ] do
        kind = kind_for(source)
        r = put_claims(record, &%{&1 | kind: kind, context_id: batch.execution_id})
        r = %{r | source_authorization: %{r.source_authorization | kind: kind}}
        b = %{batch | source: source, source_run_id: nil}

        assert SweepCorrelate.validate(r, b) == :ok, "#{source} positive"

        # Move execution_id away from the signed context; source_run_id stays absent.
        assert SweepCorrelate.validate(r, %{b | execution_id: u(0x7E)}) ==
                 {:error, {:correlation, :context_id}}
      end
    end

    test "source-run rows select source_run_id" do
      {record, batch} = control()

      for source <- [
            :SWEEP_EXECUTION_SOURCE_AD_HOC,
            :SWEEP_EXECUTION_SOURCE_ON_DEMAND,
            :SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK
          ] do
        kind = kind_for(source)
        r = put_claims(record, &%{&1 | kind: kind})
        r = %{r | source_authorization: %{r.source_authorization | kind: kind}}
        b = %{batch | source: source}

        assert SweepCorrelate.validate(r, b) == :ok, "#{source} positive"

        # Point the signed context at the NON-selected execution_id.
        r2 = put_claims(r, &%{&1 | context_id: b.execution_id})

        assert SweepCorrelate.validate(r2, b) ==
                 {:error, {:correlation, :context_id}}
      end
    end
  end

  describe "correlate_own_payload/1 — a RELATION, not a boundary" do
    defp with_payload(record, batch) do
      payload = V1.SweepObservationBatchV1.encode(batch)
      %{record | payload: payload, payload_sha256: :crypto.hash(:sha256, payload)}
    end

    test "correlates a batch carried in the record's own payload" do
      {record, batch} = control()
      assert SweepCorrelate.correlate_own_payload(with_payload(record, batch)) == :ok
    end

    test "refuses a payload the record's digest does not commit to" do
      {record, batch} = control()
      r = with_payload(record, batch)

      assert SweepCorrelate.correlate_own_payload(%{r | payload_sha256: :binary.copy(<<0>>, 32)}) ==
               {:error, {:payload, :digest_mismatch}}
    end

    test "is TOTAL: a non-record argument returns, it does not raise" do
      for bad <- [:bad, nil, %{}, "record", 42] do
        assert SweepCorrelate.correlate_own_payload(bad) == {:error, {:payload, :not_a_record}}
      end

      assert SweepCorrelate.validate(:bad, :worse) == {:error, {:payload, :not_a_record}}
    end

    test "a COMPRESSED record is refused, not mis-decoded" do
      # The relation reads record.payload directly, so a ZSTD record's bytes are the
      # compressed ones. It takes no decompressed value and so cannot honour a
      # "caller decompressed it" precondition — it refuses instead.
      {record, batch} = control()
      r = with_payload(record, batch)

      assert SweepCorrelate.correlate_own_payload(%{
               r
               | compression: :EDGE_RECORD_COMPRESSION_ZSTD
             }) == {:error, {:payload, :compressed}}

      # UNSPECIFIED is refused too: the proto default is not a declaration of NONE.
      assert SweepCorrelate.correlate_own_payload(%{
               r
               | compression: :EDGE_RECORD_COMPRESSION_UNSPECIFIED
             }) == {:error, {:payload, :compressed}}
    end

    test "a PLAIN-MAP envelope or claim body is refused, not read structurally" do
      # Without these, loosening the exact generated patterns back to %{} leaves the
      # suite green: no other negative supplies a map-shaped envelope or claims.
      {record, batch} = control()
      {:source, c} = record.source_authorization.capability.claims

      # The envelope is the only thing that varies: the claim body is the EXACT struct,
      # so this isolates the envelope pattern from the claim-body pattern.
      map_cap = %{claims: {:source, c}}
      sa1 = %{record.source_authorization | capability: map_cap}

      assert SweepCorrelate.validate(%{record | source_authorization: sa1}, batch) ==
               {:error, {:precondition, :malformed_record}}

      # The ENVELOPE stays generated; only the nested CLAIM BODY becomes a plain map.
      # With a map envelope as well, weakening just the inner
      # %EdgeSourceClaimsV1{} pattern back to %{} would go untested.
      gen_env_map_body = %V1.EdgeSignedCapabilityV1{claims: {:source, Map.from_struct(c)}}
      sa2 = %{record.source_authorization | capability: gen_env_map_body}

      assert SweepCorrelate.validate(%{record | source_authorization: sa2}, batch) ==
               {:error, {:precondition, :malformed_record}}
    end

    test "a DIFFERENT generated oneof body is refused as a kind mismatch" do
      {record, batch} = control()

      cap = %V1.EdgeSignedCapabilityV1{
        claims: {:production, %V1.EdgeProductionClaimsV1{}}
      }

      sa = %{record.source_authorization | capability: cap}

      assert SweepCorrelate.validate(%{record | source_authorization: sa}, batch) ==
               {:error, {:correlation, :source_kind}}
    end

    test "malformed NESTED shapes return typed failures, not raises" do
      {record, batch} = control()

      # PRESENT but unusable is NOT absent: the frozen `source_authority_absent` label
      # describes a genuinely omitted optional field, so a malformed one must not
      # borrow it.
      assert SweepCorrelate.validate(%{record | source_authorization: :bogus}, batch) ==
               {:error, {:precondition, :malformed_record}}

      # FAIL-CLOSED, with the EXACT reason -- never "some error". Asserting only that the
      # result is an atom would be satisfied by `:ok`, so normalizing a malformed value
      # into [], nil or 0 would pass while ACCEPTING a structurally invalid record.
      for hosts <- [
            :bogus,
            [:bogus],
            [%V1.SweepHostObservationV1{observed_at_delta_nano: 0, mtr: :bogus}]
          ] do
        assert SweepCorrelate.validate(record, %{batch | hosts: hosts}) ==
                 {:error, {:precondition, :malformed_batch}},
               "hosts=#{inspect(hosts)} was not refused"
      end

      # Non-integer times REFUSE; they are not coerced to 0, which would invent a
      # time the record never carried.
      assert SweepCorrelate.validate(record, %{batch | observed_at_unix_nano: :soon}) ==
               {:error, {:precondition, :malformed_batch}}

      assert SweepCorrelate.validate(
               record,
               %{batch | hosts: [%V1.SweepHostObservationV1{observed_at_delta_nano: :later}]}
             ) == {:error, {:precondition, :malformed_batch}}

      # A malformed RECORD field is distinguished from a malformed BATCH.
      assert SweepCorrelate.validate(%{record | producer_context: :bogus}, batch) ==
               {:error, {:precondition, :malformed_record}}

      # A PLAIN MAP with the right keys is still not what a decoded record carries.
      # Without this, weakening the exact-struct check to `is_map/1` goes unnoticed.
      plain = %{run_shard: 3, authority_epoch: 5}

      assert SweepCorrelate.validate(%{record | producer_context: plain}, batch) ==
               {:error, {:precondition, :malformed_record}}

      # Same for the source authorization and the host/MTR messages.
      plain_sa = Map.from_struct(record.source_authorization)

      assert SweepCorrelate.validate(%{record | source_authorization: plain_sa}, batch) ==
               {:error, {:precondition, :malformed_record}}

      assert SweepCorrelate.validate(record, %{batch | hosts: [%{observed_at_delta_nano: 0}]}) ==
               {:error, {:precondition, :malformed_batch}}

      plain_mtr = %V1.SweepHostObservationV1{
        observed_at_delta_nano: 0,
        mtr: %{outcome: :MTR_OUTCOME_REACHED, trace_id: <<>>}
      }

      assert SweepCorrelate.validate(record, %{batch | hosts: [plain_mtr]}) ==
               {:error, {:precondition, :malformed_batch}}
    end

    test "an UNSIGNED capability still correlates — this relation is NOT authoritative" do
      # Documented, not accidental. Signature verification, mirror checks, envelope
      # and contract dispatch are the CALLER's preconditions; this pins the boundary
      # of what the relation promises so nobody mistakes it for authority.
      {record, batch} = control()
      {:source, c} = record.source_authorization.capability.claims
      cap = %V1.EdgeSignedCapabilityV1{signature: <<>>, claims: {:source, c}}
      sa = %{record.source_authorization | capability: cap}
      r = with_payload(%{record | source_authorization: sa}, batch)

      assert SweepCorrelate.correlate_own_payload(r) == :ok
    end
  end

  defp kind_for(source) do
    {:ok, row} = ServiceRadar.Edge.SweepMatrix.fetch(source)
    row.kind
  end

  describe "the body-validator result translation (settled before 1.2-c step 3)" do
    alias ServiceRadar.Edge.SweepBodyValidate

    test "the two overlapping rules keep the FROZEN correlate outcomes" do
      # Both are decided in BOTH validators -- the disposition from two fields of the batch,
      # source admission from SweepMatrix -- so they must not surface under two different
      # shapes depending on which one ran. A caller matching the frozen outcomes keeps
      # working after step 3 routes the body validator in.
      assert SweepCorrelate.translate_body_reason({:source_run_id, :source_run_id_disposition}) ==
               {:error, {:body, :source_run_id_disposition}}

      assert SweepCorrelate.translate_body_reason({:source, :unknown}) ==
               {:error, {:enum_admission, :source}}
    end

    test "the two translations agree with what THIS module already returns" do
      # The non-vacuity control: the frozen outcomes above are the ones the correlation path
      # actually produces today, not shapes invented for the translation.
      {record, batch} = control()

      assert SweepCorrelate.validate(%{record | payload: record.payload}, %{
               batch
               | source: :SWEEP_EXECUTION_SOURCE_AD_HOC,
                 source_run_id: ""
             }) ==
               SweepCorrelate.translate_body_reason({:source_run_id, :source_run_id_disposition})

      assert SweepCorrelate.validate(record, %{
               batch
               | source: :SWEEP_EXECUTION_SOURCE_UNSPECIFIED
             }) ==
               SweepCorrelate.translate_body_reason({:source, :unknown})
    end

    test "every OTHER family enters under its own gate" do
      for family <- [
            :shape,
            :width,
            :identity,
            :checks,
            :bounds,
            :mode_bits,
            :mode_summary,
            :address,
            :check_index,
            :summary
          ] do
        assert SweepCorrelate.translate_body_reason({family, :whatever}) ==
                 {:error, {:body_validation, {family, :whatever}}}
      end
    end

    test "the mapping is TOTAL over the validator's family set, with REAL details" do
      # Each family with the detail it actually carries. A synthetic detail would send
      # `:source` down the catch-all instead of its own branch, so the assertion would pass
      # while proving nothing about the translation that matters.
      expected = %{
        shape: :body_validation,
        width: :body_validation,
        source: :enum_admission,
        source_run_id: :body,
        identity: :body_validation,
        checks: :body_validation,
        bounds: :body_validation,
        mode_bits: :body_validation,
        mode_summary: :body_validation,
        address: :body_validation,
        check_index: :body_validation,
        summary: :body_validation
      }

      details = %{source: :unknown, source_run_id: :source_run_id_disposition}

      # A family added to the body validator without a decision here fails HERE, rather than
      # arriving at the combined union as an unmatched shape.
      assert MapSet.new(Map.keys(expected)) ==
               MapSet.new(Map.keys(SweepBodyValidate.family_to_go_sentinel()))

      for {family, want_gate} <- expected do
        detail = Map.get(details, family, :some_detail)
        {:error, translated} = SweepCorrelate.translate_body_reason({family, detail})

        assert elem(translated, 0) == want_gate,
               "#{family} translated to #{inspect(translated)}, want gate #{want_gate}"
      end
    end

    test "a :source reason OTHER than :unknown is not silently given the frozen outcome" do
      # The validator emits only `{:source, :unknown}`. Anything else is a shape it never
      # produces, and mapping it onto the frozen enum-admission outcome would be a guess.
      assert SweepCorrelate.translate_body_reason({:source, :something_else}) ==
               {:error, {:body_validation, {:source, :something_else}}}
    end

    test "the new gate does not collide with the frozen ones" do
      # `{:body, label}` is frozen to carry a SweepMatrix label; routing arbitrary families
      # through it would break that invariant for existing callers.
      assert {:error, {:body_validation, _}} =
               SweepCorrelate.translate_body_reason({:summary, :x})

      refute :body_validation in [:body, :correlation, :enum_admission, :recovery_lane]
    end
  end

  describe "ingest_own_payload/1 -- the composed ingress (1.2-c step 3)" do
    alias ServiceRadar.Edge.SweepBodyValidate

    # The correlation `control/0` batch carries ONLY what correlation reads -- no plan id,
    # no policy, no checks -- so it is not a valid BODY. That is not a defect in either
    # fixture: before step 3 the two stages were reached separately, and nothing required one
    # batch to satisfy both. The composed ingress does, so this adds the body-required fields
    # WITHOUT touching any field correlation compares.
    defp ingestable do
      {_record, batch} = control()

      %{
        batch
        | execution_plan_id: u(0x21),
          availability_policy_id: "policy-1",
          batch_sequence: 1,
          tested_checks: [
            %V1.SweepTestV1{mode: :SWEEP_MODE_ICMP, protocol: :TRANSPORT_PROTOCOL_ICMP}
          ],
          configured_mode_bits: 1,
          hosts: []
      }
    end

    defp record_with_payload(batch) do
      {record, _} = control()
      payload = V1.SweepObservationBatchV1.encode(batch)

      %{
        record
        | payload: payload,
          payload_sha256: :crypto.hash(:sha256, payload)
      }
    end

    test "a valid record ingests end to end from bytes" do
      assert SweepCorrelate.ingest_own_payload(record_with_payload(ingestable())) == :ok
    end

    test "a BODY defect and a CORRELATION defect now come from ONE call" do
      batch = ingestable()

      # Body: the batch is missing identity the correlation never looks at. Before step 3
      # this reached callers only if they remembered to run the body validator first.
      body_broken = %{batch | execution_plan_sha256: ""}

      assert SweepCorrelate.ingest_own_payload(record_with_payload(body_broken)) ==
               {:error, {:body_validation, {:identity, :plan_range_digest}}}

      # Correlation: the body is fine, the signed context disagrees.
      assert SweepCorrelate.ingest_own_payload(
               record_with_payload(%{batch | execution_shard: 99})
             ) ==
               {:error, {:correlation, :execution_shard}}
    end

    test "the two SHARED rules keep their FROZEN shapes, not the body validator's" do
      batch = ingestable()

      # Disposition: SCHEDULED_CHECK requires a canonical source_run_id. The body validator
      # calls this {:source_run_id, _}; the frozen correlate outcome is {:body, _}.
      assert SweepCorrelate.ingest_own_payload(record_with_payload(%{batch | source_run_id: ""})) ==
               {:error, {:body, :source_run_id_disposition}}

      # Unknown source: the body validator calls this {:source, :unknown}.
      assert SweepCorrelate.ingest_own_payload(
               record_with_payload(%{batch | source: :SWEEP_EXECUTION_SOURCE_UNSPECIFIED})
             ) == {:error, {:enum_admission, :source}}
    end

    test "it runs the CURATED decoder, which the old path did not" do
      payload = V1.SweepObservationBatchV1.encode(ingestable()) <> <<0xFA, 0xF0, 0x04, 0x00>>

      record = %{
        elem(control(), 0)
        | payload: payload,
          payload_sha256: :crypto.hash(:sha256, payload)
      }

      # An unknown field is retained by the generated decoder and REJECTED by the curated
      # one. `correlate_own_payload/1` accepts this record; the composed ingress does not.
      assert SweepCorrelate.ingest_own_payload(record) == {:error, {:wire, :poison}}
      assert SweepCorrelate.correlate_own_payload(record) == :ok
    end

    test "decoder reasons keep their classification instead of collapsing to :decode" do
      # :poison (malformed) and :systemic (caller fault) are deliberately distinct; folding
      # both into {:payload, :decode} would discard the classification the curated decoder
      # exists to make.
      {record, _} = control()

      assert SweepCorrelate.ingest_own_payload(%{
               record
               | payload: <<0xFF, 0xFF, 0xFF>>,
                 payload_sha256: :crypto.hash(:sha256, <<0xFF, 0xFF, 0xFF>>)
             }) == {:error, {:wire, :poison}}
    end

    test "it is TOTAL, and payload plumbing still refuses before the body runs" do
      assert SweepCorrelate.ingest_own_payload(:not_a_record) ==
               {:error, {:payload, :not_a_record}}

      # A digest that does not match the payload is refused BEFORE decoding it.
      assert SweepCorrelate.ingest_own_payload(%{
               record_with_payload(ingestable())
               | payload_sha256: :binary.copy(<<0>>, 32)
             }) == {:error, {:payload, :digest_mismatch}}
    end

    test "every body family reaches the union through the frozen translation" do
      # The composed path must not invent shapes: whatever the body validator returns is
      # translated, never passed through raw.
      batch = ingestable()

      for {mutate, family} <- [
            {&%{&1 | execution_plan_sha256: ""}, :identity},
            {&%{&1 | tested_checks: []}, :checks},
            {&%{&1 | configured_mode_bits: 999}, :mode_bits}
          ] do
        got = SweepCorrelate.ingest_own_payload(record_with_payload(mutate.(batch)))
        assert {:error, {:body_validation, {^family, _}}} = got

        # ...and it is EXACTLY what translate_body_reason/1 would have produced.
        {:error, raw} = SweepBodyValidate.validate(mutate.(batch))
        assert got == SweepCorrelate.translate_body_reason(raw)
      end
    end
  end
end
