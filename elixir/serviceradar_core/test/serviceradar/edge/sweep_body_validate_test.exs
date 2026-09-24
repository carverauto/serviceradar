defmodule ServiceRadar.Edge.SweepBodyValidateTest do
  @moduledoc """
  The Elixir peer of `ValidateSweepObservationBatch` (task 1.2-c, step 2).

  Fixtures are REAL generated structs. Hand-built maps have twice hidden defects in these
  gates, because a map clears predicates a decoded message does not.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias ServiceRadar.Edge.SemanticValidate
  alias ServiceRadar.Edge.SweepBodyValidate, as: Body
  alias ServiceRadar.Edge.SweepCorrelate
  alias ServiceRadar.Edge.SweepOutcomePolicy
  alias Serviceradar.Edge.V1, as: V1

  # --- widths, restated here so the test does not read them from the subject -------------
  @u32_max 4_294_967_295
  @u64_max 18_446_744_073_709_551_615
  @i64_max 9_223_372_036_854_775_807
  @i64_min -9_223_372_036_854_775_808
  @i32_max 2_147_483_647

  defp uuid(seed), do: <<seed::8, 0::40, 7::4, 0::12, 0b10::2, 0::62>>
  defp d32(seed), do: :binary.copy(<<seed>>, 32)

  defp icmp_check,
    do: %V1.SweepTestV1{mode: :SWEEP_MODE_ICMP, protocol: :TRANSPORT_PROTOCOL_ICMP, port: 0}

  defp tcp_check,
    do: %V1.SweepTestV1{mode: :SWEEP_MODE_TCP_SYN, protocol: :TRANSPORT_PROTOCOL_TCP, port: 443}

  defp icmp_summary,
    do: %V1.SweepIcmpSummaryV1{
      outcome: :SWEEP_MODE_OUTCOME_SUCCESS,
      target_reached: true,
      round_trip_micro: 1200,
      packet_loss_pct: 0.0,
      sent: 3,
      received: 3
    }

  defp tcp_summary,
    do: %V1.SweepTcpSummaryV1{
      outcome: :SWEEP_MODE_OUTCOME_SUCCESS,
      tested_count: 1,
      open_count: 1
    }

  defp mtr_summary,
    do: %V1.SweepMtrSummaryV1{
      trace_id: uuid(0x71),
      outcome: :MTR_OUTCOME_REACHED,
      target_reached: true,
      final_rtt_micro: 9000,
      packet_loss_pct: 0.0,
      total_hops: 4,
      error_code: ""
    }

  # ICMP + TCP_SYN named; one open port referencing the TCP check at index 1.
  defp host do
    %V1.SweepHostObservationV1{
      address: <<192, 168, 1, 10>>,
      hostname: "host-a",
      observed_at_delta_nano: -500,
      first_seen_delta_nano: nil,
      last_seen_delta_nano: nil,
      result_mode_bits: 1 ||| 2,
      mode_revision: 1,
      icmp: icmp_summary(),
      tcp: tcp_summary(),
      mtr: nil,
      open_ports: [
        %V1.SweepOpenPortV1{tested_check_index: 1, response_time_nano: 4000, service: "https"}
      ],
      port_errors: []
    }
  end

  defp mtr_check,
    do: %V1.SweepTestV1{mode: :SWEEP_MODE_MTR, protocol: :TRANSPORT_PROTOCOL_ICMP, port: 0}

  # Naming the MTR bit in a host requires the BATCH to configure an MTR check: result bits
  # must be a subset of configured, so an MTR host on the two-check fixture is refused by
  # the subset rule before any MTR rule is reached.
  defp mtr_batch(summary) do
    hh = %{host() | result_mode_bits: 1 ||| 2 ||| 8, mtr: summary}

    %{
      batch()
      | tested_checks: [icmp_check(), tcp_check(), mtr_check()],
        configured_mode_bits: 1 ||| 2 ||| 8,
        hosts: [hh]
    }
  end

  defp batch do
    %V1.SweepObservationBatchV1{
      source: :SWEEP_EXECUTION_SOURCE_AD_HOC,
      source_run_id: uuid(0x23),
      execution_id: uuid(0x20),
      sweep_group_id: "",
      execution_shard: 2,
      assignment_epoch: 9,
      execution_plan_id: uuid(0x21),
      target_range_id: uuid(0x22),
      execution_plan_sha256: d32(0xBB),
      target_range_sha256: d32(0xAA),
      availability_policy_id: "policy-1",
      batch_sequence: 1,
      observed_at_unix_nano: 1_700_000_300_000_000_000,
      configured_mode_bits: 1 ||| 2,
      tested_checks: [icmp_check(), tcp_check()],
      hosts: [host()]
    }
  end

  # --- focused mutators -----------------------------------------------------------------
  defp b(field, v), do: Map.put(batch(), field, v)
  defp h(field, v), do: %{batch() | hosts: [Map.put(host(), field, v)]}

  defp sub(summary_key, field, v) do
    hh = host()
    updated = Map.put(Map.fetch!(hh, summary_key), field, v)
    %{batch() | hosts: [%{hh | summary_key => updated}]}
  end

  defp chk(idx, field, v) do
    checks = List.update_at(batch().tested_checks, idx, &Map.put(&1, field, v))
    %{batch() | tested_checks: checks}
  end

  defp error_entry(field, v) do
    hh = host()
    pe = [Map.put(%V1.SweepPortErrorV1{tested_check_index: 1, error_code: "refused"}, field, v)]
    %{batch() | hosts: [%{hh | open_ports: [], tcp: tcp_summary(), port_errors: pe}]}
  end

  defp port_entry(field, v) do
    hh = host()
    op = [Map.put(hd(hh.open_ports), field, v)]
    %{batch() | hosts: [%{hh | open_ports: op}]}
  end

  test "the fixture is VALID -- every rejection below is one axis off this" do
    assert Body.validate(batch()) == :ok
  end

  test "an MTR-carrying host is valid too" do
    assert Body.validate(mtr_batch(mtr_summary())) == :ok
  end

  test "validate/1 is TOTAL -- any term, never a raise" do
    for bad <- [nil, :batch, 7, %{}, [], "bytes", {:tuple}, %URI{}] do
      assert Body.validate(bad) == {:error, {:shape, :not_a_batch}}, "#{inspect(bad)}"
    end
  end

  # =======================================================================================
  # BOUNDS, ENUMERATED PER PROTOBUF INTEGER WIDTH
  #
  # One table per width, never a single "is it an integer in range" table: a `uint32` field
  # guarded against the `uint64` ceiling accepts 2^32, which the wire cannot carry.
  # =======================================================================================

  # Each entry: {name, fn value -> batch end}. Both directions are asserted -- the ceiling
  # value must NOT be a width rejection, and ceiling+1 must be exactly {:width, width}.
  @uint32_fields [
    {"batch.execution_shard", &__MODULE__.mut_execution_shard/1},
    {"batch.configured_mode_bits", &__MODULE__.mut_configured_mode_bits/1},
    {"tested_check.port", &__MODULE__.mut_port/1},
    {"host.result_mode_bits", &__MODULE__.mut_result_mode_bits/1},
    {"host.mode_revision", &__MODULE__.mut_mode_revision/1},
    {"open_port.tested_check_index", &__MODULE__.mut_open_port_index/1},
    {"port_error.tested_check_index", &__MODULE__.mut_port_error_index/1},
    {"icmp.sent", &__MODULE__.mut_icmp_sent/1},
    {"icmp.received", &__MODULE__.mut_icmp_received/1},
    {"tcp.tested_count", &__MODULE__.mut_tcp_tested/1},
    {"tcp.open_count", &__MODULE__.mut_tcp_open/1},
    {"mtr.total_hops", &__MODULE__.mut_mtr_hops/1}
  ]

  @uint64_fields [
    {"batch.assignment_epoch", &__MODULE__.mut_assignment_epoch/1},
    {"batch.batch_sequence", &__MODULE__.mut_batch_sequence/1},
    {"open_port.response_time_nano", &__MODULE__.mut_response_time/1},
    {"icmp.round_trip_micro", &__MODULE__.mut_round_trip/1},
    {"mtr.final_rtt_micro", &__MODULE__.mut_final_rtt/1}
  ]

  @int64_fields [{"batch.observed_at_unix_nano", &__MODULE__.mut_observed_at/1}]

  @sint64_fields [
    {"host.observed_at_delta_nano", &__MODULE__.mut_delta/1},
    {"host.first_seen_delta_nano", &__MODULE__.mut_first_seen/1},
    {"host.last_seen_delta_nano", &__MODULE__.mut_last_seen/1}
  ]

  @enum_int32_fields [
    {"batch.source", &__MODULE__.mut_source/1},
    {"tested_check.mode", &__MODULE__.mut_mode/1},
    {"tested_check.protocol", &__MODULE__.mut_protocol/1},
    {"icmp.outcome", &__MODULE__.mut_icmp_outcome/1},
    {"tcp.outcome", &__MODULE__.mut_tcp_outcome/1},
    {"mtr.outcome", &__MODULE__.mut_mtr_outcome/1}
  ]

  def mut_execution_shard(v), do: b(:execution_shard, v)
  def mut_configured_mode_bits(v), do: b(:configured_mode_bits, v)
  def mut_port(v), do: chk(1, :port, v)
  def mut_result_mode_bits(v), do: h(:result_mode_bits, v)
  def mut_mode_revision(v), do: h(:mode_revision, v)
  def mut_open_port_index(v), do: port_entry(:tested_check_index, v)
  def mut_port_error_index(v), do: error_entry(:tested_check_index, v)
  def mut_icmp_sent(v), do: sub(:icmp, :sent, v)
  def mut_icmp_received(v), do: sub(:icmp, :received, v)
  def mut_tcp_tested(v), do: sub(:tcp, :tested_count, v)
  def mut_tcp_open(v), do: sub(:tcp, :open_count, v)
  def mut_assignment_epoch(v), do: b(:assignment_epoch, v)
  def mut_batch_sequence(v), do: b(:batch_sequence, v)
  def mut_response_time(v), do: port_entry(:response_time_nano, v)
  def mut_round_trip(v), do: sub(:icmp, :round_trip_micro, v)
  def mut_observed_at(v), do: b(:observed_at_unix_nano, v)
  def mut_delta(v), do: h(:observed_at_delta_nano, v)
  def mut_first_seen(v), do: h(:first_seen_delta_nano, v)
  def mut_last_seen(v), do: h(:last_seen_delta_nano, v)
  def mut_source(v), do: b(:source, v)
  def mut_mode(v), do: chk(0, :mode, v)
  def mut_protocol(v), do: chk(0, :protocol, v)
  def mut_icmp_outcome(v), do: sub(:icmp, :outcome, v)
  def mut_tcp_outcome(v), do: sub(:tcp, :outcome, v)

  # The MTR summary is absent from the default host, so its fields need the MTR variant.
  defp with_mtr(field, v), do: mtr_batch(Map.put(mtr_summary(), field, v))

  def mut_mtr_hops(v), do: with_mtr(:total_hops, v)
  def mut_final_rtt(v), do: with_mtr(:final_rtt_micro, v)
  def mut_mtr_outcome(v), do: with_mtr(:outcome, v)

  # A width rejection must be reported as {:width, width} and nothing else; the ceiling
  # itself must not be a width rejection (it may still fail a SEMANTIC rule, which is a
  # different family -- asserting :ok here would be asserting the wrong thing).
  defp assert_width(name, mutate, ceiling, over, width) do
    at = Body.validate(mutate.(ceiling))

    refute match?({:error, {:width, _}}, at),
           "#{name}: the #{width} ceiling itself was rejected as out of width (#{inspect(at)})"

    assert Body.validate(mutate.(over)) == {:error, {:width, width}},
           "#{name}: #{inspect(over)} was not refused as an out-of-#{width} value"
  end

  test "uint32 fields reject 2^32 and accept 2^32-1" do
    for {name, mutate} <- @uint32_fields do
      assert_width(name, mutate, @u32_max, @u32_max + 1, :uint32)
      assert Body.validate(mutate.(-1)) == {:error, {:width, :uint32}}, "#{name}: -1 accepted"
    end
  end

  test "uint64 fields reject 2^64 and accept 2^64-1" do
    for {name, mutate} <- @uint64_fields do
      assert_width(name, mutate, @u64_max, @u64_max + 1, :uint64)
      assert Body.validate(mutate.(-1)) == {:error, {:width, :uint64}}, "#{name}: -1 accepted"
    end
  end

  test "int64 fields reject both ends of the signed range" do
    for {name, mutate} <- @int64_fields do
      assert_width(name, mutate, @i64_max, @i64_max + 1, :int64)

      assert Body.validate(mutate.(@i64_min - 1)) == {:error, {:width, :int64}},
             "#{name}: below int64 min accepted"

      refute match?({:error, {:width, _}}, Body.validate(mutate.(@i64_min)))
    end
  end

  test "sint64 fields reject both ends -- a NEGATIVE delta is normal here" do
    for {name, mutate} <- @sint64_fields do
      assert_width(name, mutate, @i64_max, @i64_max + 1, :sint64)

      assert Body.validate(mutate.(@i64_min - 1)) == {:error, {:width, :sint64}},
             "#{name}: below sint64 min accepted"

      # The control that keeps this distinct from uint64: negatives are IN domain.
      refute match?({:error, {:width, _}}, Body.validate(mutate.(-1)))
    end
  end

  test "enum fields carry int32 on the wire, and an out-of-int32 value is a WIDTH failure" do
    # proto3 enums are OPEN: an unrecognized value decodes to a bare integer. That integer
    # is an int32, so this is the only place int32 range is reachable at all.
    for {name, mutate} <- @enum_int32_fields do
      assert Body.validate(mutate.(@i32_max + 1)) == {:error, {:width, :enum_int32}},
             "#{name}: above int32 max accepted"

      assert Body.validate(mutate.(-2_147_483_649)) == {:error, {:width, :enum_int32}},
             "#{name}: below int32 min accepted"

      # In-range but unknown is a DOMAIN question, not a width one, so it must NOT be
      # reported as a width failure.
      refute match?({:error, {:width, _}}, Body.validate(mutate.(4242))),
             "#{name}: an in-range unknown enum was called a width failure"
    end
  end

  test "the width tables cover EVERY integer field in the eight message inventories" do
    # Derived from the descriptors, not hand-counted: a hand-counted total does not notice
    # an added field, and a call site missing from a table survives weakening its branch.
    covered =
      MapSet.new(
        @uint32_fields ++ @uint64_fields ++ @int64_fields ++ @sint64_fields ++ @enum_int32_fields,
        fn {name, _} ->
          name
        end
      )

    expected =
      for {mod, fields} <- inventories(),
          {_fnum, name, type, _card} <- fields,
          width = width_of(type),
          width != nil,
          into: MapSet.new() do
        "#{short(mod)}.#{name}"
      end

    assert covered == expected
  end

  # =======================================================================================
  # SHAPES
  # =======================================================================================

  describe "shape rejections" do
    test "a wrong scalar type is a shape failure, not a width one" do
      for {name, mutate, want} <- [
            {"bytes field given an atom", &__MODULE__.mut_source_run_id/1, {:shape, :bytes}},
            {"uint32 given a float", &__MODULE__.mut_execution_shard/1, {:shape, :uint32}},
            {"uint64 given a float", &__MODULE__.mut_batch_sequence/1, {:shape, :uint64}},
            {"int64 given a binary", &__MODULE__.mut_observed_at/1, {:shape, :int64}}
          ] do
        v = if elem(want, 1) == :bytes, do: :not_bytes, else: bad_scalar(elem(want, 1))
        assert Body.validate(mutate.(v)) == {:error, want}, name
      end
    end

    test "a string field must be a binary AND valid UTF-8" do
      assert Body.validate(h(:hostname, 7)) == {:error, {:shape, :string}}
      # Go refuses invalid UTF-8 at DECODE, so only a hand-built struct holds it here.
      assert Body.validate(h(:hostname, <<0xFF, 0xFE>>)) == {:error, {:shape, :string_utf8}}
    end

    test "a bool field must be a boolean" do
      assert Body.validate(sub(:icmp, :target_reached, :yes)) == {:error, {:shape, :bool}}
      assert Body.validate(sub(:icmp, :target_reached, 1)) == {:error, {:shape, :bool}}
    end

    test "a repeated field must be a list of the right struct" do
      assert Body.validate(b(:tested_checks, :nope)) == {:error, {:shape, :tested_checks}}
      assert Body.validate(b(:hosts, %{})) == {:error, {:shape, :hosts}}
      assert Body.validate(b(:tested_checks, [%URI{}])) == {:error, {:shape, :tested_check}}
      assert Body.validate(b(:hosts, [:host])) == {:error, {:shape, :host}}
    end

    test "an optional message must be that message or absent" do
      assert Body.validate(h(:icmp, %URI{})) == {:error, {:shape, :icmp}}
      assert Body.validate(h(:tcp, %V1.SweepIcmpSummaryV1{})) == {:error, {:shape, :tcp}}
    end

    test "an enum field must be an atom or an integer" do
      assert Body.validate(b(:source, "AD_HOC")) == {:error, {:shape, :enum}}
      assert Body.validate(b(:source, nil)) == {:error, {:shape, :enum}}
    end
  end

  def mut_source_run_id(v), do: b(:source_run_id, v)

  defp bad_scalar(:uint32), do: 1.5
  defp bad_scalar(:uint64), do: 1.5
  defp bad_scalar(:int64), do: "when"

  # =======================================================================================
  # DOMAIN / SEMANTIC RULES, in Go's order
  # =======================================================================================

  describe "source and disposition" do
    test "an unknown source is refused by enum admission" do
      assert Body.validate(b(:source, :SWEEP_EXECUTION_SOURCE_UNSPECIFIED)) ==
               {:error, {:source, :unknown}}

      assert Body.validate(b(:source, 4242)) == {:error, {:source, :unknown}}
    end

    test "the disposition is decided HERE, from two fields of this message" do
      # AD_HOC REQUIRES a canonical source_run_id.
      assert Body.validate(b(:source_run_id, "")) ==
               {:error, {:source_run_id, :source_run_id_disposition}}

      assert Body.validate(b(:source_run_id, <<0::128>>)) ==
               {:error, {:source_run_id, :source_run_id_disposition}}

      # SCHEDULED_SWEEP FORBIDS it, and the fixture carries one.
      assert Body.validate(b(:source, :SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP)) ==
               {:error, {:source_run_id, :source_run_id_disposition}}
    end
  end

  describe "identity" do
    test "each of the three ids must be a canonical UUID" do
      for f <- [:execution_id, :execution_plan_id, :target_range_id] do
        assert Body.validate(b(f, <<0::128>>)) == {:error, {:identity, :ids}}, "#{f}"
        assert Body.validate(b(f, "")) == {:error, {:identity, :ids}}, "#{f} empty"
      end
    end

    test "plan and range digests must be exactly 32 bytes" do
      for f <- [:execution_plan_sha256, :target_range_sha256] do
        assert Body.validate(b(f, :binary.copy(<<1>>, 31))) ==
                 {:error, {:identity, :plan_range_digest}}

        assert Body.validate(b(f, :binary.copy(<<1>>, 33))) ==
                 {:error, {:identity, :plan_range_digest}}
      end
    end

    test "policy, sequence and timestamp must all be present" do
      assert Body.validate(b(:availability_policy_id, "")) ==
               {:error, {:identity, :policy_sequence_timestamp}}

      assert Body.validate(b(:batch_sequence, 0)) ==
               {:error, {:identity, :policy_sequence_timestamp}}

      assert Body.validate(b(:observed_at_unix_nano, 0)) ==
               {:error, {:identity, :policy_sequence_timestamp}}

      assert Body.validate(b(:observed_at_unix_nano, -1)) ==
               {:error, {:identity, :policy_sequence_timestamp}}
    end
  end

  describe "tested checks" do
    test "the set must be non-empty" do
      assert Body.validate(b(:tested_checks, [])) == {:error, {:checks, :empty}}
    end

    test "an unknown mode is refused" do
      assert Body.validate(chk(0, :mode, :SWEEP_MODE_UNSPECIFIED)) ==
               {:error, {:checks, :unknown_mode}}

      assert Body.validate(chk(0, :mode, 4242)) == {:error, {:checks, :unknown_mode}}
    end

    test "mode, protocol and port must agree" do
      # ICMP rides ICMP with port 0.
      assert Body.validate(chk(0, :protocol, :TRANSPORT_PROTOCOL_TCP)) ==
               {:error, {:checks, :mode_protocol_port}}

      assert Body.validate(chk(0, :port, 80)) == {:error, {:checks, :mode_protocol_port}}

      # TCP rides TCP on 1..65535.
      assert Body.validate(chk(1, :protocol, :TRANSPORT_PROTOCOL_ICMP)) ==
               {:error, {:checks, :mode_protocol_port}}

      assert Body.validate(chk(1, :port, 0)) == {:error, {:checks, :mode_protocol_port}}
      assert Body.validate(chk(1, :port, 65_536)) == {:error, {:checks, :mode_protocol_port}}
      refute match?({:error, _}, Body.validate(chk(1, :port, 65_535)))
    end

    test "a duplicate check is refused on the (mode, protocol, port) triple" do
      dup = %{batch() | tested_checks: [icmp_check(), tcp_check(), tcp_check()]}
      assert Body.validate(dup) == {:error, {:checks, :duplicate}}
    end

    test "configured_mode_bits must EQUAL the bits derived from the checks" do
      assert Body.validate(b(:configured_mode_bits, 1)) == {:error, {:mode_bits, :configured}}
      # Superset is refused too, not just subset.
      assert Body.validate(b(:configured_mode_bits, 1 ||| 2 ||| 8)) ==
               {:error, {:mode_bits, :configured}}
    end

    test "more than 2000 hosts is a bounds failure" do
      over = %{batch() | hosts: List.duplicate(host(), 2001)}
      assert Body.validate(over) == {:error, {:bounds, :hosts}}
      # 2000 exactly is accepted -- the boundary is pinned, not bracketed.
      assert Body.validate(%{batch() | hosts: List.duplicate(host(), 2000)}) == :ok
    end
  end

  describe "per-host rules" do
    test "an address must be 4 or 16 bytes" do
      for a <- [<<>>, <<1, 2, 3>>, :binary.copy(<<1>>, 5), :binary.copy(<<1>>, 15)] do
        assert Body.validate(h(:address, a)) == {:error, {:address, :length}},
               "#{byte_size(a)} bytes accepted"
      end

      refute match?({:error, _}, Body.validate(h(:address, :binary.copy(<<1>>, 16))))
    end

    test "result bits must be non-zero and a SUBSET of configured" do
      assert Body.validate(h(:result_mode_bits, 0)) == {:error, {:mode_bits, :result}}
      # Bit 8 (MTR) is not configured by the fixture's checks, so naming it is a SUBSET
      # violation -- caught before any MTR summary rule runs.
      hh = %{host() | result_mode_bits: 1 ||| 8, mtr: mtr_summary()}
      assert Body.validate(%{batch() | hosts: [hh]}) == {:error, {:mode_bits, :result}}
    end

    test "a named mode MUST carry its summary" do
      assert Body.validate(h(:icmp, nil)) == {:error, {:mode_summary, :icmp_missing}}
      assert Body.validate(h(:tcp, nil)) == {:error, {:mode_summary, :tcp_missing}}

      assert Body.validate(mtr_batch(nil)) == {:error, {:mode_summary, :mtr_missing}}
    end

    test "an UNNAMED mode must NOT carry a summary" do
      # Both directions matter: a summary for a mode this fragment does not claim is
      # unattributable, so presence is as wrong as absence.
      hh = %{host() | result_mode_bits: 2, icmp: icmp_summary()}
      assert Body.validate(%{batch() | hosts: [hh]}) == {:error, {:mode_summary, :icmp_unnamed}}

      hh2 = %{host() | result_mode_bits: 1, tcp: tcp_summary(), open_ports: []}
      assert Body.validate(%{batch() | hosts: [hh2]}) == {:error, {:mode_summary, :tcp_unnamed}}

      # MTR is CONFIGURED here but not named by this fragment, so the subset rule passes
      # and the unnamed-summary rule is what refuses it.
      hh3 = %{host() | result_mode_bits: 1 ||| 2, mtr: mtr_summary()}
      bb = %{mtr_batch(mtr_summary()) | hosts: [hh3]}
      assert Body.validate(bb) == {:error, {:mode_summary, :mtr_unnamed}}
    end
  end

  describe "summary counters" do
    test "icmp: outcome, received <= sent, and reached implies received > 0" do
      assert Body.validate(sub(:icmp, :outcome, :SWEEP_MODE_OUTCOME_UNSPECIFIED)) ==
               {:error, {:summary, :icmp_outcome}}

      assert Body.validate(sub(:icmp, :outcome, 99)) == {:error, {:summary, :icmp_outcome}}

      assert Body.validate(sub(:icmp, :received, 4)) ==
               {:error, {:summary, :icmp_received_gt_sent}}

      zero = %{icmp_summary() | sent: 0, received: 0, target_reached: true}
      hh = %{host() | icmp: zero}

      assert Body.validate(%{batch() | hosts: [hh]}) ==
               {:error, {:summary, :icmp_reached_zero_received}}
    end

    test "tcp: outcome and open <= tested" do
      assert Body.validate(sub(:tcp, :outcome, :SWEEP_MODE_OUTCOME_UNSPECIFIED)) ==
               {:error, {:summary, :tcp_outcome}}

      # open_count must also match the listed open ports, so move both together.
      t = %{tcp_summary() | tested_count: 1, open_count: 2}
      hh = %{host() | tcp: t, open_ports: List.duplicate(hd(host().open_ports), 2)}

      assert Body.validate(%{batch() | hosts: [hh]}) ==
               {:error, {:summary, :tcp_open_gt_tested}}
    end

    test "mtr: only TERMINAL outcomes, and a trace id exactly when one is ALLOCATED" do
      assert Body.validate(with_mtr(:outcome, :MTR_OUTCOME_UNSPECIFIED)) ==
               {:error, {:summary, :mtr_outcome}}

      # Allocated outcomes REQUIRE a UUIDv7 trace id.
      for o <- [
            :MTR_OUTCOME_REACHED,
            :MTR_OUTCOME_TARGET_UNREACHABLE,
            :MTR_OUTCOME_PROBE_FAILED,
            :MTR_OUTCOME_TIMED_OUT
          ] do
        m = %{mtr_summary() | outcome: o, trace_id: "", target_reached: false, total_hops: 1}

        assert Body.validate(mtr_batch(m)) == {:error, {:summary, :mtr_trace_id}},
               "#{o} accepted without a trace id"
      end

      # A v4 UUID is canonical but NOT v7.
      v4 = <<0x30::8, 0::40, 4::4, 0::12, 0b10::2, 0::62>>
      assert Body.validate(with_mtr(:trace_id, v4)) == {:error, {:summary, :mtr_trace_id}}

      # Non-allocated outcomes must carry NONE.
      for o <- [
            :MTR_OUTCOME_NOT_ADMITTED,
            :MTR_OUTCOME_QUARANTINED,
            :MTR_OUTCOME_SCHEDULER_LOST
          ] do
        m = %{mtr_summary() | outcome: o, target_reached: false, total_hops: 0}

        assert Body.validate(mtr_batch(m)) == {:error, {:summary, :mtr_unallocated_trace_id}},
               "#{o} kept its trace id"

        # ...and the same outcome WITHOUT one is fine: this is the non-vacuity control.
        assert Body.validate(mtr_batch(%{m | trace_id: ""})) == :ok
      end
    end

    test "mtr: reached implies at least one hop" do
      assert Body.validate(mtr_batch(%{mtr_summary() | target_reached: true, total_hops: 0})) ==
               {:error, {:summary, :mtr_reached_zero_hops}}
    end

    test "packet loss must be a real percentage in [0,100]" do
      for {name, v} <- [{"negative", -0.1}, {"over 100", 100.1}] do
        assert Body.validate(sub(:icmp, :packet_loss_pct, v)) == {:error, {:summary, :icmp_loss}},
               "icmp #{name} accepted"

        assert Body.validate(with_mtr(:packet_loss_pct, v)) == {:error, {:summary, :mtr_loss}},
               "mtr #{name} accepted"
      end

      for edge <- [0.0, 100.0] do
        refute match?({:error, _}, Body.validate(sub(:icmp, :packet_loss_pct, edge)))
      end

      # ABSENT is distinct from a present zero and is allowed.
      refute match?({:error, _}, Body.validate(sub(:icmp, :packet_loss_pct, nil)))
    end

    test "NaN and the infinities are wire-REACHABLE and are refused by the DOMAIN rule" do
      # protobuf-elixir decodes these IEEE bit patterns to atoms, because an Erlang float
      # cannot hold them. They are therefore values of a `double` field that arrive from
      # the wire -- not shape errors -- and Go refuses the same three via IsNaN/IsInf.
      for special <- [:nan, :infinity, :negative_infinity] do
        assert Body.validate(sub(:icmp, :packet_loss_pct, special)) ==
                 {:error, {:summary, :icmp_loss}},
               "icmp #{special} accepted"

        assert Body.validate(with_mtr(:packet_loss_pct, special)) ==
                 {:error, {:summary, :mtr_loss}},
               "mtr #{special} accepted"
      end
    end

    test "the NaN/Inf atoms really do come off the wire" do
      # The control for the test above: if the decoder produced floats or raised, the
      # atoms would be unreachable and those vectors would be testing nothing.
      for {bits, want} <- [
            {<<0, 0, 0, 0, 0, 0, 0xF8, 0x7F>>, :nan},
            {<<0, 0, 0, 0, 0, 0, 0xF0, 0x7F>>, :infinity},
            {<<0, 0, 0, 0, 0, 0, 0xF0, 0xFF>>, :negative_infinity}
          ] do
        decoded = V1.SweepMtrSummaryV1.decode(<<0x29>> <> bits)
        assert decoded.packet_loss_pct == want
      end
    end
  end

  describe "open-port and error check indices" do
    test "an index must be in range" do
      assert Body.validate(port_entry(:tested_check_index, 2)) ==
               {:error, {:check_index, :out_of_range}}
    end

    test "an index must name a TCP check whose bit is in THIS fragment's result bits" do
      # Index 0 is the ICMP check.
      assert Body.validate(port_entry(:tested_check_index, 0)) ==
               {:error, {:check_index, :not_a_named_tcp_check}}

      # A TCP check that exists but whose bit the fragment does not claim.
      checks = [icmp_check(), tcp_check(), %{tcp_check() | mode: :SWEEP_MODE_TCP_CONNECT}]
      hh = %{host() | open_ports: [%V1.SweepOpenPortV1{tested_check_index: 2, service: "x"}]}

      bb = %{
        batch()
        | tested_checks: checks,
          configured_mode_bits: 1 ||| 2 ||| 4,
          hosts: [hh]
      }

      assert Body.validate(bb) == {:error, {:check_index, :not_a_named_tcp_check}}
    end

    test "an index may appear at most once ACROSS open_ports and port_errors" do
      hh = %{
        host()
        | open_ports: [%V1.SweepOpenPortV1{tested_check_index: 1, service: "https"}],
          port_errors: [%V1.SweepPortErrorV1{tested_check_index: 1, error_code: "refused"}]
      }

      # An index both open AND errored is a conflicting claim about the same port.
      assert Body.validate(%{batch() | hosts: [hh]}) == {:error, {:check_index, :duplicate}}
    end

    test "listed open ports must match the TCP summary's open_count EXACTLY" do
      two = List.duplicate(%V1.SweepOpenPortV1{tested_check_index: 1, service: "https"}, 2)
      # Duplicate index is caught first, so use distinct indices.
      checks = [icmp_check(), tcp_check(), %{tcp_check() | mode: :SWEEP_MODE_TCP_CONNECT}]

      hh = %{
        host()
        | result_mode_bits: 1 ||| 2 ||| 4,
          open_ports: [
            %V1.SweepOpenPortV1{tested_check_index: 1, service: "https"},
            %V1.SweepOpenPortV1{tested_check_index: 2, service: "http"}
          ],
          tcp: %{tcp_summary() | tested_count: 2, open_count: 1}
      }

      bb = %{batch() | tested_checks: checks, configured_mode_bits: 1 ||| 2 ||| 4, hosts: [hh]}
      assert Body.validate(bb) == {:error, {:summary, :open_count_mismatch}}
      assert length(two) == 2

      # And the matching case is accepted, so the rule is not vacuously failing.
      ok = %{hh | tcp: %{tcp_summary() | tested_count: 2, open_count: 2}}
      assert Body.validate(%{bb | hosts: [ok]}) == :ok
    end

    test "open ports without any TCP summary" do
      # Reachable only when the fragment names TCP but omits the summary... which the
      # named-mode rule catches first. This pins that ordering rather than claiming an
      # unreachable branch is covered.
      assert Body.validate(h(:tcp, nil)) == {:error, {:mode_summary, :tcp_missing}}
    end
  end

  # =======================================================================================
  # ORDER AND THE FAMILY MAP
  # =======================================================================================

  test "when several rules are violated, the FIRST in Go's order is reported" do
    # Source is checked before identity, identity before checks, checks before hosts.
    broken =
      batch()
      |> Map.put(:source, :SWEEP_EXECUTION_SOURCE_UNSPECIFIED)
      |> Map.put(:execution_id, <<0::128>>)
      |> Map.put(:tested_checks, [])
      |> Map.put(:hosts, [%{host() | address: <<>>}])

    assert Body.validate(broken) == {:error, {:source, :unknown}}

    assert Body.validate(%{broken | source: :SWEEP_EXECUTION_SOURCE_AD_HOC}) ==
             {:error, {:identity, :ids}}

    assert Body.validate(%{
             broken
             | source: :SWEEP_EXECUTION_SOURCE_AD_HOC,
               execution_id: uuid(0x20)
           }) ==
             {:error, {:checks, :empty}}
  end

  test "the remaining BATCH-level precedences are pinned too" do
    over = List.duplicate(host(), 2001)

    # disposition BEFORE identity: AD_HOC without a source_run_id, and a bad execution id.
    assert Body.validate(%{batch() | source_run_id: "", execution_id: <<0::128>>}) ==
             {:error, {:source_run_id, :source_run_id_disposition}}

    # the host ceiling BEFORE per-check content: a non-empty but INVALID check set.
    assert Body.validate(%{
             batch()
             | hosts: over,
               tested_checks: [%{icmp_check() | protocol: :TRANSPORT_PROTOCOL_TCP}]
           }) == {:error, {:bounds, :hosts}}

    # the host ceiling BEFORE the configured-bits comparison.
    assert Body.validate(%{batch() | hosts: over, configured_mode_bits: 1}) ==
             {:error, {:bounds, :hosts}}
  end

  test "the per-HOST rules keep Go's order too" do
    # The batch-level order test above says nothing about the host loop, where Go runs
    # address -> result bits -> named summaries -> summary contents -> check indices ->
    # open-port count. Each pair below violates TWO rules and pins which one answers.
    hh = host()

    # address BEFORE result bits
    assert Body.validate(%{batch() | hosts: [%{hh | address: <<1>>, result_mode_bits: 0}]}) ==
             {:error, {:address, :length}}

    # result bits BEFORE named summaries: bit 8 is not configured, and tcp is also absent.
    assert Body.validate(%{batch() | hosts: [%{hh | result_mode_bits: 1 ||| 8, tcp: nil}]}) ==
             {:error, {:mode_bits, :result}}

    # named summaries BEFORE summary CONTENTS: tcp is named but missing, while the icmp
    # summary that IS present carries an inadmissible outcome.
    named_first = %{
      hh
      | tcp: nil,
        open_ports: [],
        icmp: %{icmp_summary() | outcome: :SWEEP_MODE_OUTCOME_UNSPECIFIED}
    }

    assert Body.validate(%{batch() | hosts: [named_first]}) ==
             {:error, {:mode_summary, :tcp_missing}}

    # summary contents BEFORE check indices: bad icmp outcome and an out-of-range index.
    contents_first = %{
      hh
      | icmp: %{icmp_summary() | outcome: :SWEEP_MODE_OUTCOME_UNSPECIFIED},
        open_ports: [%V1.SweepOpenPortV1{tested_check_index: 99, service: "x"}]
    }

    assert Body.validate(%{batch() | hosts: [contents_first]}) ==
             {:error, {:summary, :icmp_outcome}}

    # check indices BEFORE the open-port count: a bad index and a mismatched open_count.
    # open_count stays <= tested_count, so the SUMMARY is valid and only the index and the
    # listed-port count are wrong -- otherwise this would test the summary boundary instead.
    index_first = %{
      hh
      | open_ports: [%V1.SweepOpenPortV1{tested_check_index: 99, service: "x"}],
        tcp: %{tcp_summary() | tested_count: 7, open_count: 7}
    }

    assert Body.validate(%{batch() | hosts: [index_first]}) ==
             {:error, {:check_index, :out_of_range}}
  end

  test "the structural pass runs BEFORE the semantic one" do
    # A batch that is both out-of-width and semantically broken reports the width, because
    # the semantic pass would otherwise compare a value the wire cannot carry.
    both = %{b(:batch_sequence, @u64_max + 1) | execution_id: <<0::128>>}
    assert Body.validate(both) == {:error, {:width, :uint64}}
  end

  test "the family -> Go sentinel mapping is pinned EXACTLY" do
    # Uniqueness plus an "ErrSweep" prefix would pass with any sentinel typo'd onto any
    # family, which is the whole content of the claim.
    assert Body.family_to_go_sentinel() == %{
             shape: nil,
             width: nil,
             source: "ErrSweepSource",
             source_run_id: "ErrSweepSourceRunID",
             identity: "ErrSweepIdentity",
             checks: "ErrSweepChecks",
             bounds: "ErrSweepBounds",
             mode_bits: "ErrSweepModeBits",
             mode_summary: "ErrSweepModeSummary",
             address: "ErrSweepAddress",
             check_index: "ErrSweepCheckIndex",
             summary: "ErrSweepSummary"
           }
  end

  # THE SENTINEL-EXISTENCE CHECK IS DELIBERATELY ABSENT. It used to read `domain.go` from
  # this Elixir test and grep for each name, which (a) is not stageable -- Bazel does not
  # give the Elixir shard the Go source tree, so it failed there while passing under
  # `mix test`, and (b) was strictly WEAKER than what already exists. Go's
  # `TestSweepBodyFamilySentinelsAreBehavioural` references every sentinel as an IDENTIFIER,
  # so a name that does not exist fails to COMPILE, and it further asserts each branch
  # actually returns that sentinel. Grepping a source file proves less and couples this
  # suite to Go's file layout.

  test "every family in the map is REACHABLE by some vector" do
    # An unreachable family would be a reason that documents a rule nothing enforces.
    reached =
      MapSet.new(
        [
          Body.validate(:not_a_batch),
          Body.validate(b(:batch_sequence, @u64_max + 1)),
          Body.validate(b(:source, :SWEEP_EXECUTION_SOURCE_UNSPECIFIED)),
          Body.validate(b(:source_run_id, "")),
          Body.validate(b(:execution_id, <<0::128>>)),
          Body.validate(b(:tested_checks, [])),
          Body.validate(%{batch() | hosts: List.duplicate(host(), 2001)}),
          Body.validate(b(:configured_mode_bits, 1)),
          Body.validate(h(:icmp, nil)),
          Body.validate(h(:address, <<1>>)),
          Body.validate(port_entry(:tested_check_index, 2)),
          Body.validate(sub(:icmp, :received, 99))
        ],
        fn {:error, {family, _}} -> family end
      )

    assert reached == MapSet.new(Map.keys(Body.family_to_go_sentinel()))
  end

  # =======================================================================================
  # THE STRUCTURAL PREFLIGHT
  # =======================================================================================

  describe "the host ceiling runs BEFORE anything walks the hosts" do
    test "an over-long list of MALFORMED hosts reports the bound, not the shape" do
      over = %{batch() | hosts: List.duplicate(:not_a_host, 2001)}
      assert Body.validate(over) == {:error, {:bounds, :hosts}}
    end

    test "the count STOPS at the ceiling -- an improper tail beyond it is never reached" do
      # The deterministic form of "it does not traverse the whole list": impropriety past
      # the cap cannot be observed, because the walk has already stopped.
      beyond = List.duplicate(host(), 2001) ++ :tail
      assert Body.validate(%{batch() | hosts: beyond}) == {:error, {:bounds, :hosts}}

      # ...and the SAME defect under the cap IS observed, so the pair is not vacuous.
      within = List.duplicate(host(), 3) ++ :tail
      assert Body.validate(%{batch() | hosts: within}) == {:error, {:shape, :improper_list}}
    end

    test "the CONFIGURED-BITS comparison also precedes host structure" do
      # Go compares configured bits before its host loop, and that violation is
      # representable in Go while a malformed host is not. Validating host structure first
      # would answer a Go-representable input with a precondition family Go has no peer for.
      bb = %{batch() | configured_mode_bits: 1, hosts: [:not_a_host]}
      assert Body.validate(bb) == {:error, {:mode_bits, :configured}}
    end

    test "the bound keeps Go's precedence: source and identity still come first" do
      over = List.duplicate(host(), 2001)

      assert Body.validate(%{
               batch()
               | hosts: over,
                 source: :SWEEP_EXECUTION_SOURCE_UNSPECIFIED
             }) == {:error, {:source, :unknown}}

      assert Body.validate(%{batch() | hosts: over, execution_id: <<0::128>>}) ==
               {:error, {:identity, :ids}}

      # Go checks the empty check-set before the host bound.
      assert Body.validate(%{batch() | hosts: over, tested_checks: []}) ==
               {:error, {:checks, :empty}}
    end
  end

  describe "improper lists are refused, not raised on" do
    test "every repeated field" do
      assert Body.validate(b(:tested_checks, [icmp_check()] ++ :tail)) ==
               {:error, {:shape, :improper_list}}

      assert Body.validate(b(:hosts, [host()] ++ :tail)) == {:error, {:shape, :improper_list}}

      assert Body.validate(h(:open_ports, [hd(host().open_ports)] ++ :tail)) ==
               {:error, {:shape, :improper_list}}

      pe = %V1.SweepPortErrorV1{tested_check_index: 1, error_code: "refused"}

      assert Body.validate(h(:port_errors, [pe] ++ :tail)) ==
               {:error, {:shape, :improper_list}}

      # `[] ++ :tail` is just `:tail` -- not a list at all, so it is a field-shape failure
      # rather than an improper-list one. Keeping both pins which check answers.
      assert Body.validate(h(:port_errors, [] ++ :tail)) == {:error, {:shape, :port_errors}}
    end

    test "is_list/1 alone would have raised" do
      # The trap this closes: `is_list([x | :tail])` is TRUE, so the shape check passes and
      # Enum.reduce_while/3 then raises FunctionClauseError on the tail.
      assert is_list([host() | :tail])
    end
  end

  describe "wire hygiene on the decoded struct" do
    test "a retained unknown field is refused" do
      poisoned = %{batch() | __unknown_fields__: [{9999, 2, "x"}]}
      assert Body.validate(poisoned) == {:error, {:shape, :unknown_fields}}
    end

    test "the EXACT-FRAME check runs on all EIGHT message types" do
      # One axis per message. Without a control for each, removing message_frame/1 from any
      # single helper survives -- which it did for tcp, mtr and port_error.
      pe = %V1.SweepPortErrorV1{tested_check_index: 1, error_code: "refused"}
      uf = [{1, 0, "x"}]

      cases = [
        {"batch", Map.put(batch(), :smuggled, 1)},
        {"tested_check", chk(0, :smuggled, 1)},
        {"host", h(:smuggled, 1)},
        {"icmp", sub(:icmp, :smuggled, 1)},
        {"tcp", sub(:tcp, :smuggled, 1)},
        {"mtr", with_mtr(:smuggled, 1)},
        {"open_port", port_entry(:smuggled, 1)},
        {"port_error", error_entry(:smuggled, 1)}
      ]

      for {name, bad} <- cases do
        assert Body.validate(bad) == {:error, {:shape, :extra_fields}}, "#{name} extra key"
      end

      unknown = [
        {"batch", %{batch() | __unknown_fields__: uf}},
        {"tested_check", chk(0, :__unknown_fields__, uf)},
        {"host", h(:__unknown_fields__, uf)},
        {"icmp", sub(:icmp, :__unknown_fields__, uf)},
        {"tcp", sub(:tcp, :__unknown_fields__, uf)},
        {"mtr", with_mtr(:__unknown_fields__, uf)},
        {"open_port", port_entry(:__unknown_fields__, uf)},
        {"port_error", error_entry(:__unknown_fields__, uf)}
      ]

      for {name, bad} <- unknown do
        assert Body.validate(bad) == {:error, {:shape, :unknown_fields}}, "#{name} unknown"
      end

      assert length(cases) == 8 and length(unknown) == 8
      assert pe == %V1.SweepPortErrorV1{tested_check_index: 1, error_code: "refused"}
    end

    test "unknown fields are refused at EVERY nesting depth" do
      for {name, bad} <- [
            {"tested_check",
             %{
               batch()
               | tested_checks: [%{icmp_check() | __unknown_fields__: [{1, 0, "x"}]}, tcp_check()]
             }},
            {"host", h(:__unknown_fields__, [{1, 0, "x"}])},
            {"icmp summary", sub(:icmp, :__unknown_fields__, [{1, 0, "x"}])},
            {"open port", port_entry(:__unknown_fields__, [{1, 0, "x"}])}
          ] do
        assert Body.validate(bad) == {:error, {:shape, :unknown_fields}}, name
      end
    end

    test "an EXTRA struct key is refused" do
      # `%Mod{}` in a pattern compiles to `%{__struct__: Mod}`, so an extra key survives
      # every struct match; only comparing the generated key set refuses it.
      assert Body.validate(Map.put(batch(), :smuggled, 1)) == {:error, {:shape, :extra_fields}}
      assert Body.validate(h(:smuggled, 1)) == {:error, {:shape, :extra_fields}}
    end

    test "an arbitrary ATOM in an enum field is refused" do
      # The generated encoder cannot represent `:FUTURE`, so it is not a wire value -- only
      # a hand-built struct holds it. A generated-but-unadmitted member is a DOMAIN question
      # and must still reach the semantic gate, which the control below pins.
      assert Body.validate(b(:source, :FUTURE)) == {:error, {:shape, :enum}}
      assert Body.validate(chk(0, :mode, :SWEEP_MODE_FUTURE)) == {:error, {:shape, :enum}}
      assert Body.validate(sub(:icmp, :outcome, :WHATEVER)) == {:error, {:shape, :enum}}

      assert Body.validate(b(:source, :SWEEP_EXECUTION_SOURCE_UNSPECIFIED)) ==
               {:error, {:source, :unknown}}
    end
  end

  describe "validate_bytes/1 -- the composed ingress" do
    test "valid extracted bytes validate end to end AND return the batch" do
      # Returning a bare :ok would force the caller to decode a second time, or to bypass
      # this function and compose the two stages itself -- the seam it exists to remove.
      assert Body.validate_bytes(V1.SweepObservationBatchV1.encode(batch())) ==
               {:ok, batch()}
    end

    test "an unknown field on the WIRE is refused, which validate/1 alone cannot see" do
      # field 9999, wire type 2, zero length
      bytes = V1.SweepObservationBatchV1.encode(batch()) <> <<0xFA, 0xF0, 0x04, 0x00>>
      assert Body.validate_bytes(bytes) == {:error, :poison}
    end

    test "decoder failures pass through unchanged" do
      assert Body.validate_bytes(<<0xFF, 0xFF, 0xFF>>) == {:error, :poison}
      assert Body.validate_bytes(:not_binary) == {:error, :systemic}

      assert Body.validate_bytes(:binary.copy(<<0xFF>>, 32 * 1024 * 1024 + 1)) ==
               {:error, :too_large}
    end

    test "ALL FOUR decoder reasons propagate, including :not_ready" do
      # :not_ready needs an unloaded schema module, so driving it through validate_bytes/1
      # would need a seam in the decoder. This maps the outcome directly -- the same code
      # path validate_bytes/1 takes, not a double.
      for reason <- [:too_large, :poison, :not_ready, :systemic] do
        assert Body.propagate_decode_error({:error, reason}) == {:error, reason}
      end
    end

    test "the mapping is exhaustive over WireDecode's reason type" do
      # If the decoder grows a reason, this fails rather than silently leaving it unproven.
      {:ok, specs} = Code.Typespec.fetch_types(ServiceRadar.Edge.WireDecode)

      for_result =
        for {:type, {:reason, {:type, _, :union, members}, _}} <- specs do
          Enum.map(members, fn {:atom, _, a} -> a end)
        end

      reasons = List.flatten(for_result)

      assert MapSet.new(reasons) == MapSet.new([:too_large, :poison, :not_ready, :systemic])
    end

    # The helper is ERROR-ONLY: a version that also built `{:ok, batch}` would be a public
    # way to mint a "validated" batch for bytes that never went through the decoder. That
    # property is enforced at COMPILE time -- its spec and single clause take only
    # `{:error, reason}`, and Elixir's type checker rejects an `{:ok, _}` argument outright,
    # including through a function capture. A runtime test would be strictly weaker, so
    # there is deliberately not one.

    test "a body that decodes but fails validation reports the BODY reason" do
      bad = V1.SweepObservationBatchV1.encode(%{batch() | batch_sequence: 0})
      assert Body.validate_bytes(bad) == {:error, {:identity, :policy_sequence_timestamp}}
    end
  end

  # =======================================================================================
  # DESCRIPTOR INVENTORIES AND BORROWED DOMAINS
  # =======================================================================================

  @inventories %{
    V1.SweepObservationBatchV1 => [
      {1, "execution_id", :bytes, :singular},
      {2, "sweep_group_id", :bytes, :singular},
      {3, "execution_shard", :uint32, :singular},
      {4, "assignment_epoch", :uint64, :singular},
      {5, "batch_sequence", :uint64, :singular},
      {6, "observed_at_unix_nano", :int64, :singular},
      {7, "execution_plan_id", :bytes, :singular},
      {8, "execution_plan_sha256", :bytes, :singular},
      {9, "target_range_id", :bytes, :singular},
      {10, "target_range_sha256", :bytes, :singular},
      {11, "tested_checks", V1.SweepTestV1, :repeated},
      {12, "configured_mode_bits", :uint32, :singular},
      {13, "availability_policy_id", :bytes, :singular},
      {14, "source", {:enum, V1.SweepExecutionSource}, :singular},
      {15, "source_run_id", :bytes, :singular},
      {16, "hosts", V1.SweepHostObservationV1, :repeated}
    ],
    V1.SweepTestV1 => [
      {1, "mode", {:enum, V1.SweepMode}, :singular},
      {2, "protocol", {:enum, V1.TransportProtocol}, :singular},
      {3, "port", :uint32, :singular}
    ],
    V1.SweepHostObservationV1 => [
      {1, "address", :bytes, :singular},
      {2, "hostname", :string, :singular},
      {3, "observed_at_delta_nano", :sint64, :singular},
      {4, "first_seen_delta_nano", :sint64, :optional},
      {5, "last_seen_delta_nano", :sint64, :optional},
      {6, "result_mode_bits", :uint32, :singular},
      {7, "mode_revision", :uint32, :singular},
      {8, "icmp", V1.SweepIcmpSummaryV1, :optional},
      {9, "tcp", V1.SweepTcpSummaryV1, :optional},
      {10, "open_ports", V1.SweepOpenPortV1, :repeated},
      {11, "port_errors", V1.SweepPortErrorV1, :repeated},
      {12, "mtr", V1.SweepMtrSummaryV1, :optional}
    ],
    V1.SweepIcmpSummaryV1 => [
      {1, "outcome", {:enum, V1.SweepModeOutcome}, :singular},
      {2, "target_reached", :bool, :singular},
      {3, "round_trip_micro", :uint64, :optional},
      {4, "packet_loss_pct", :double, :optional},
      {5, "sent", :uint32, :singular},
      {6, "received", :uint32, :singular}
    ],
    V1.SweepTcpSummaryV1 => [
      {1, "outcome", {:enum, V1.SweepModeOutcome}, :singular},
      {2, "tested_count", :uint32, :singular},
      {3, "open_count", :uint32, :singular}
    ],
    V1.SweepMtrSummaryV1 => [
      {1, "trace_id", :bytes, :singular},
      {2, "outcome", {:enum, V1.MtrOutcome}, :singular},
      {3, "target_reached", :bool, :singular},
      {4, "final_rtt_micro", :uint64, :optional},
      {5, "packet_loss_pct", :double, :optional},
      {6, "total_hops", :uint32, :singular},
      {7, "error_code", :string, :singular}
    ],
    V1.SweepOpenPortV1 => [
      {1, "tested_check_index", :uint32, :singular},
      {2, "response_time_nano", :uint64, :optional},
      {3, "service", :string, :singular}
    ],
    V1.SweepPortErrorV1 => [
      {1, "tested_check_index", :uint32, :singular},
      {2, "error_code", :string, :singular}
    ]
  }

  @short %{
    V1.SweepObservationBatchV1 => "batch",
    V1.SweepTestV1 => "tested_check",
    V1.SweepHostObservationV1 => "host",
    V1.SweepIcmpSummaryV1 => "icmp",
    V1.SweepTcpSummaryV1 => "tcp",
    V1.SweepMtrSummaryV1 => "mtr",
    V1.SweepOpenPortV1 => "open_port",
    V1.SweepPortErrorV1 => "port_error"
  }

  defp inventories, do: @inventories
  defp short(mod), do: Map.fetch!(@short, mod)

  defp width_of(:uint32), do: :uint32
  defp width_of(:uint64), do: :uint64
  defp width_of(:int64), do: :int64
  defp width_of(:sint64), do: :sint64
  defp width_of({:enum, _}), do: :enum_int32
  defp width_of(_), do: nil

  defp descriptor_fields(mod) do
    props = mod.__message_props__()

    props.field_props
    |> Map.values()
    |> Enum.sort_by(& &1.fnum)
    |> Enum.map(fn f ->
      card =
        cond do
          f.repeated? -> :repeated
          f.proto3_optional? -> :optional
          true -> :singular
        end

      {f.fnum, Atom.to_string(f.name_atom), f.type, card}
    end)
  end

  test "all EIGHT message inventories are pinned against the generated descriptors" do
    # By field NUMBER, NAME, TYPE and CARDINALITY. A hand-written table of call sites cannot
    # notice a field being added or its protobuf type changing; this can, and it is what
    # makes the width-coverage test above total rather than a count.
    for {mod, frozen} <- inventories() do
      assert descriptor_fields(mod) == frozen,
             "#{inspect(mod)} drifted from its frozen inventory"
    end
  end

  test "the inventory covers every message this validator walks" do
    assert MapSet.new(Map.keys(@inventories)) == MapSet.new(Map.keys(@short))
    assert map_size(@inventories) == 8
  end

  describe "borrowed domains -- no second copy of an existing authority" do
    test "admitted enum members come from the SemanticValidate policy" do
      policy = SemanticValidate.enum_field_policy()

      # If the validator restated these, deleting a member here would leave it green.
      assert :SWEEP_MODE_OUTCOME_UNKNOWN in Map.fetch!(policy, {V1.SweepIcmpSummaryV1, :outcome})

      refute Body.validate(sub(:icmp, :outcome, :SWEEP_MODE_OUTCOME_UNKNOWN)) ==
               {:error, {:summary, :icmp_outcome}}

      for o <- Map.fetch!(policy, {V1.SweepMtrSummaryV1, :outcome}) do
        refute Body.validate(with_mtr(:outcome, o)) == {:error, {:summary, :mtr_outcome}},
               "#{o} is admitted by the policy but refused by the validator"
      end
    end

    test "the allocated-MTR subset comes from SweepCorrelate and is a SUBSET of terminal" do
      allocated = SweepOutcomePolicy.trace_allocating_outcomes()

      terminal =
        Map.fetch!(SemanticValidate.enum_field_policy(), {V1.SweepMtrSummaryV1, :outcome})

      assert MapSet.subset?(MapSet.new(allocated), MapSet.new(terminal))

      # Allocated outcomes REQUIRE a trace id; the rest must carry none. Driving both loops
      # from the shared lists is what keeps this from becoming a fourth copy.
      for o <- allocated do
        m = %{mtr_summary() | outcome: o, target_reached: false, total_hops: 1, trace_id: ""}
        assert Body.validate(mtr_batch(m)) == {:error, {:summary, :mtr_trace_id}}
      end

      for o <- terminal -- allocated do
        m = %{mtr_summary() | outcome: o, target_reached: false, total_hops: 0}
        assert Body.validate(mtr_batch(m)) == {:error, {:summary, :mtr_unallocated_trace_id}}
      end
    end

    test "mode-bit NUMBERS come from the generated SweepModeBit" do
      # Only the mode -> bit-name correspondence is local; renumbering a generated bit must
      # move this validator with Go rather than leave a stale literal behind.
      mapping = V1.SweepModeBit.mapping()

      assert Body.mode_bit_names() == %{
               SWEEP_MODE_ICMP: :SWEEP_MODE_BIT_ICMP,
               SWEEP_MODE_TCP_SYN: :SWEEP_MODE_BIT_TCP_SYN,
               SWEEP_MODE_TCP_CONNECT: :SWEEP_MODE_BIT_TCP_CONNECT,
               SWEEP_MODE_MTR: :SWEEP_MODE_BIT_MTR
             }

      for {_mode, bit_name} <- Body.mode_bit_names() do
        assert Map.has_key?(mapping, bit_name), "#{bit_name} is not a generated SweepModeBit"
      end

      # The batch fixture's configured bits are exactly ICMP|TCP_SYN as the generated enum
      # numbers them, so the fixture agrees with the generated values rather than literals.
      assert batch().configured_mode_bits ==
               Bitwise.bor(mapping[:SWEEP_MODE_BIT_ICMP], mapping[:SWEEP_MODE_BIT_TCP_SYN])
    end

    test "the TCP/ICMP partition is EXACT over the admitted mode set" do
      {tcp, icmp} = Body.mode_partition()
      admitted = Map.fetch!(SemanticValidate.enum_field_policy(), {V1.SweepTestV1, :mode})

      assert MapSet.new(tcp ++ icmp) == MapSet.new(admitted),
             "a mode is admitted but in neither protocol arm, or vice versa"

      assert tcp -- icmp == tcp, "the two arms overlap"
    end

    test "the trace-allocation policy module depends on NEITHER consumer" do
      # Reading it off SweepCorrelate made this module depend on the correlation module,
      # while step 3 routes this module INTO that one -- a MUTUAL edge, and not the one-way
      # edge the ledger records. The import table is the structural proof, not a comment.
      {:ok, {_mod, [imports: imports]}} =
        :beam_lib.chunks(:code.which(SweepOutcomePolicy), [:imports])

      called = MapSet.new(imports, fn {m, _f, _a} -> m end)

      refute MapSet.member?(called, SweepCorrelate)
      refute MapSet.member?(called, Body)

      # ...and both consumers really do route through it, so the module is not dead code
      # that the two of them bypass.
      for consumer <- [Body, SweepCorrelate] do
        {:ok, {_m, [imports: imps]}} = :beam_lib.chunks(:code.which(consumer), [:imports])
        mods = MapSet.new(imps, fn {m, _f, _a} -> m end)

        assert MapSet.member?(mods, SweepOutcomePolicy),
               "#{inspect(consumer)} does not use the shared policy"
      end
    end

    test "the source domain agrees with SweepMatrix" do
      policy =
        Map.fetch!(SemanticValidate.enum_field_policy(), {V1.SweepObservationBatchV1, :source})

      assert MapSet.new(policy) ==
               MapSet.new(Map.keys(ServiceRadar.Edge.SweepMatrix.matrix()))
    end
  end
end
