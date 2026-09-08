defmodule ServiceRadar.Edge.SweepMatrixTest do
  @moduledoc """
  The Elixir peer of Go's `sweep_inventory_test.go`.

  Both runtimes pin the SAME frozen matrix as literals. These literals are
  deliberately NOT derived from `SweepMatrix.matrix/0`: a test that reads the
  table it is checking passes for any table.

  The inventory has TWO parts and only ONE is descriptor-derived. SOURCE and KIND
  are enum domains, so they are checked against the GENERATED protobuf enum
  modules and a renumbering fails. OPERAND and DISPOSITION are not enum domains
  and no descriptor knows them — they are literal table entries, exactly as they
  are in Go.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SweepMatrix

  @frozen [
    {:SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP, 1, :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
     1, :execution_id, :forbidden},
    {:SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE, 2, :EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE, 2,
     :execution_id, :forbidden},
    {:SWEEP_EXECUTION_SOURCE_AD_HOC, 3, :EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC, 4, :source_run_id,
     :required},
    {:SWEEP_EXECUTION_SOURCE_ON_DEMAND, 4, :EDGE_SOURCE_AUTHORIZATION_KIND_ON_DEMAND, 5,
     :source_run_id, :required},
    {:SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK, 5, :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK,
     3, :source_run_id, :required}
  ]

  @source_mod Serviceradar.Edge.V1.SweepExecutionSource
  @kind_mod Serviceradar.Edge.V1.EdgeSourceAuthorizationKind

  describe "descriptor-derived columns" do
    test "every frozen source and kind matches the generated enum name and number" do
      for {source, source_num, kind, kind_num, _operand, _disp} <- @frozen do
        assert @source_mod.value(source) == source_num,
               "source #{source} number drifted from the frozen #{source_num}"

        assert @source_mod.key(source_num) == source

        assert @kind_mod.value(kind) == kind_num,
               "kind #{kind} number drifted from the frozen #{kind_num}"

        assert @kind_mod.key(kind_num) == kind
      end
    end

    test "both unreachable kinds are real generated members, so excluding them is not vacuous" do
      for kind <- SweepMatrix.unreachable_kinds() do
        assert is_integer(@kind_mod.value(kind)),
               "#{kind} is not a generated member; the exclusion would assert nothing"
      end
    end

    # BOTH GENERATED DOMAINS ARE PARTITIONED EXHAUSTIVELY against literals.
    #
    # Checking only that the five expected rows exist is not a totality proof: a
    # NEW generated source or kind passes it untouched. And an inventory that
    # walks only its own expectation lists goes vacuous when one of those lists
    # shrinks -- deleting an entry from unreachable_kinds/0 silently removed its
    # check. Every generated member must land in EXACTLY ONE literal bucket, and
    # every literal must name a real member.
    test "the SweepExecutionSource domain is exactly unspecified + the mapped rows" do
      assert_partition(
        "SweepExecutionSource",
        enum_members(@source_mod),
        [:SWEEP_EXECUTION_SOURCE_UNSPECIFIED | Enum.map(@frozen, &elem(&1, 0))]
      )
    end

    test "the EdgeSourceAuthorizationKind domain is exactly unspecified + mapped + unreachable" do
      assert_partition(
        "EdgeSourceAuthorizationKind",
        enum_members(@kind_mod),
        [:EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED | Enum.map(@frozen, &elem(&1, 2))] ++
          SweepMatrix.unreachable_kinds()
      )
    end
  end

  describe "the mapping's shape" do
    test "is TOTAL over the frozen sources" do
      assert MapSet.new(Map.keys(SweepMatrix.matrix())) ==
               MapSet.new(Enum.map(@frozen, &elem(&1, 0)))
    end

    test "is INJECTIVE into kinds" do
      kinds = SweepMatrix.matrix() |> Map.values() |> Enum.map(& &1.kind)
      assert length(kinds) == length(Enum.uniq(kinds))
    end

    test "excludes both unreachable kinds from its range" do
      range = SweepMatrix.matrix() |> Map.values() |> MapSet.new(& &1.kind)

      for kind <- SweepMatrix.unreachable_kinds() do
        refute MapSet.member?(range, kind), "#{kind} is reachable but declared unreachable"
      end
    end

    test "does not admit UNSPECIFIED, so an unset field cannot select a mapping" do
      assert SweepMatrix.fetch(:SWEEP_EXECUTION_SOURCE_UNSPECIFIED) == :error
      refute SweepMatrix.known_source?(:SWEEP_EXECUTION_SOURCE_UNSPECIFIED)
    end
  end

  describe "literal columns" do
    test "the implementation's operand and disposition equal the frozen literals" do
      for {source, _sn, kind, _kn, operand, disposition} <- @frozen do
        assert {:ok, row} = SweepMatrix.fetch(source)
        assert row.kind == kind
        assert row.operand == operand, "#{source}: operand drifted"
        assert row.source_run_id == disposition, "#{source}: disposition drifted"
      end
    end
  end

  describe "portable labels" do
    # An exact SET, not a sequence: no manifest exists yet to give an order its
    # authority, and the spec's prose enumerates them differently. Asserting an
    # order none of them agree on would pin an accident.
    test "are exactly the fifteen frozen label names" do
      frozen = [
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

      assert length(frozen) == 15
      assert length(SweepMatrix.labels()) == 15, "the implementation lists a label twice"
      assert MapSet.new(SweepMatrix.labels()) == MapSet.new(frozen)
    end
  end

  describe "source_run_id disposition" do
    # Per row, not sampled: a disposition declared per row and proven on one row
    # leaves the others unenforced.
    test "forbidden rows reject a present id and accept its absence" do
      for {source, _, _, _, _, :forbidden} <- @frozen do
        {:ok, row} = SweepMatrix.fetch(source)
        assert SweepMatrix.check_source_run_id(row, nil) == :ok

        assert SweepMatrix.check_source_run_id(row, uuid()) ==
                 {:error, :source_run_id_disposition}
      end
    end

    test "required rows reject absence and accept a canonical id" do
      for {source, _, _, _, _, :required} <- @frozen do
        {:ok, row} = SweepMatrix.fetch(source)
        assert SweepMatrix.check_source_run_id(row, uuid()) == :ok
        assert SweepMatrix.check_source_run_id(row, nil) == {:error, :source_run_id_disposition}
      end
    end

    # Three shapes, because "canonical UUID" is three independent predicates.
    # Length alone would leave the version and variant checks unproven.
    test "required rows reject every malformed shape" do
      for {source, _, _, _, _, :required} <- @frozen do
        {:ok, row} = SweepMatrix.fetch(source)

        for {name, id} <- [
              {"wrong length", <<1, 2, 3>>},
              {"bad version", bad_version()},
              {"bad variant", bad_variant()},
              {"all zero", <<0::128>>}
            ] do
          assert SweepMatrix.check_source_run_id(row, id) ==
                   {:error, :source_run_id_disposition},
                 "#{source}/#{name} was accepted"
        end
      end
    end
  end

  describe "context operand" do
    test "selects exactly the field its row names" do
      batch = %{execution_id: <<0xAA::128>>, source_run_id: <<0xBB::128>>}

      for {source, _, _, _, operand, _} <- @frozen do
        {:ok, row} = SweepMatrix.fetch(source)
        expected = Map.fetch!(batch, operand)

        assert SweepMatrix.context_operand(row, batch) == expected,
               "#{source} selected the wrong operand"
      end
    end
  end

  # Every generated member of an enum module, via its generated descriptor.
  # `mapping/0` is the generated name->number map, so this reads the GENERATED
  # domain rather than any list the test itself maintains.
  defp enum_members(mod), do: mod.mapping() |> Map.keys() |> MapSet.new()

  # Fails in EITHER direction: an unclassified generated member, or a literal that
  # names nothing generated and would therefore make its own checks vacuous.
  defp assert_partition(name, generated, want) do
    want_set = MapSet.new(want)

    assert MapSet.size(want_set) == length(want),
           "#{name}: the literal partition lists a member twice"

    unclassified = MapSet.difference(generated, want_set)

    assert MapSet.size(unclassified) == 0,
           "#{name}: generated members in no literal bucket: #{inspect(MapSet.to_list(unclassified))}"

    phantom = MapSet.difference(want_set, generated)

    assert MapSet.size(phantom) == 0,
           "#{name}: literals naming no generated member (checks over them are vacuous): #{inspect(MapSet.to_list(phantom))}"
  end

  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<a::48, 7::4, b::12, 0b10::2, c::62>>
  end

  defp bad_version do
    <<a::48, _::4, rest::bitstring>> = uuid()
    <<a::48, 0::4, rest::bitstring>>
  end

  defp bad_variant do
    <<a::64, b::2, rest::bitstring>> = uuid()
    _ = b
    <<a::64, 0b11::2, rest::bitstring>>
  end
end
