defmodule ServiceRadar.Edge.StreamRouteTest do
  @moduledoc """
  Asserts the route map against the NORMATIVE subject topology in the `nats-tenant-isolation`
  spec, not against whatever the code happens to emit.

  The earlier version of this test derived its expectations from the generated enums. That looked
  rigorous and was not: it proved the code agreed with itself, so it passed while the code emitted
  an entirely invented `sr.edge.v1.*` subject space and treated the declared-but-inactive
  `CONTINUOUS_V1` as routable. Enum membership is an ABI fact; the active route map is a
  DEPLOYMENT fact, and only the spec can settle the second.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.ResolvedRoute
  alias ServiceRadar.Edge.StreamRoute

  @durable :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
  @recovery :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
  @continuous :EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1

  @bulk :EDGE_RECORD_TRAFFIC_CLASS_BULK
  @interactive :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE

  defp scope(seed), do: :crypto.hash(:sha256, <<seed::32>>)

  defp contract(profile, class, seed \\ 1) do
    %{route_profile: profile, traffic_class: class, network_scope_id: scope(seed)}
  end

  describe "the normative subject topology" do
    test "durable records publish to telemetry.edge-record.v1.{class}.pNN" do
      assert {:ok, %ResolvedRoute{} = bulk} = StreamRoute.resolve(contract(@durable, @bulk))
      assert bulk.subject =~ ~r"^telemetry\.edge-record\.v1\.bulk\.p\d{2}$"

      assert {:ok, inter} = StreamRoute.resolve(contract(@durable, @interactive))
      assert inter.subject =~ ~r"^telemetry\.edge-record\.v1\.interactive\.p\d{2}$"
    end

    test "recovery is ONE singular subject: no class token, no partition token" do
      assert {:ok, from_bulk} = StreamRoute.resolve(contract(@recovery, @bulk))
      assert {:ok, from_inter} = StreamRoute.resolve(contract(@recovery, @interactive))

      assert from_bulk.subject == "telemetry.edge-record-recovery.v1"
      assert from_inter.subject == from_bulk.subject
      assert from_bulk.expected_stream == from_inter.expected_stream

      # nil, NOT 0. Zero is a real partition; conflating "unpartitioned" with "partition zero"
      # is how a singular subject acquires a partitioned neighbour's semantics.
      assert from_bulk.partition == nil
    end

    test "the DLQ is class-separated and partitioned" do
      assert {:ok, b} = StreamRoute.resolve_dlq(@bulk, 3)
      assert {:ok, i} = StreamRoute.resolve_dlq(@interactive, 3)

      assert b.subject == "telemetry.edge-record-dlq.v1.bulk.p03"
      assert i.subject == "telemetry.edge-record-dlq.v1.interactive.p03"
      refute b.expected_stream == i.expected_stream
    end

    test "no subject outside the five normative families is emitted" do
      subjects =
        for {p, c} <- StreamRoute.active_lanes() do
          {:ok, r} = StreamRoute.resolve(contract(p, c))
          r.subject
        end ++
          for c <- [@bulk, @interactive], part <- [0, 63] do
            {:ok, r} = StreamRoute.resolve_dlq(c, part)
            r.subject
          end

      for s <- subjects do
        assert s =~
                 ~r"^telemetry\.(edge-record\.v1\.(bulk|interactive)\.p\d{2}|edge-record-recovery\.v1|edge-record-dlq\.v1\.(bulk|interactive)\.p\d{2})$",
               "#{s} is outside the normative subject families"
      end

      # The old invented namespace must not reappear.
      refute Enum.any?(subjects, &String.starts_with?(&1, "sr.edge."))
    end
  end

  describe "recovery DLQ does not collapse" do
    test "a recovery failure preserves its ORIGINAL class" do
      # Recovery's DATA lane collapses both classes onto one subject...
      {:ok, data_bulk} = StreamRoute.resolve(contract(@recovery, @bulk))
      {:ok, data_inter} = StreamRoute.resolve(contract(@recovery, @interactive))
      assert data_bulk.subject == data_inter.subject

      # ...but its DLQ must NOT. Merging them would let a bulk poison cohort queue ahead of the
      # interactive reserve, which is the exact thing the class-separated DLQ exists to prevent.
      {:ok, dlq_bulk} = StreamRoute.resolve_dlq(@bulk, 7)
      {:ok, dlq_inter} = StreamRoute.resolve_dlq(@interactive, 7)

      refute dlq_bulk.subject == dlq_inter.subject
      refute dlq_bulk.expected_stream == dlq_inter.expected_stream
    end

    test "resolve_dlq/2 cannot even express a route profile, so recovery has no DLQ of its own" do
      # A structural guarantee, not a runtime check: the arity admits no profile.
      refute function_exported?(StreamRoute, :resolve_dlq, 3)
    end
  end

  describe "the active route map is not the enum" do
    test "CONTINUOUS_V1 is declared in the ABI but is NOT routable" do
      assert :EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1 in Map.keys(
               Serviceradar.Edge.V1.EdgeRecordRouteProfile.mapping()
             ),
             "precondition: the enum still declares CONTINUOUS_V1"

      # Activating it requires the benchmarked platform change plus provisioned streams. Routing
      # it now would resolve to a stream that does not exist.
      assert {:error, :unroutable_lane} = StreamRoute.resolve(contract(@continuous, @bulk))
      assert {:error, :unroutable_lane} = StreamRoute.resolve(contract(@continuous, @interactive))

      refute Enum.any?(StreamRoute.active_lanes(), fn {p, _} -> p == @continuous end)
    end

    test "every active lane resolves, and the active set is exactly the four expected" do
      assert Enum.sort(StreamRoute.active_lanes()) ==
               Enum.sort([
                 {@durable, @bulk},
                 {@durable, @interactive},
                 {@recovery, @bulk},
                 {@recovery, @interactive}
               ])

      for {p, c} <- StreamRoute.active_lanes() do
        assert {:ok, %ResolvedRoute{}} = StreamRoute.resolve(contract(p, c))
      end
    end

    test "unspecified members are unroutable" do
      assert {:error, _} =
               StreamRoute.resolve(contract(:EDGE_RECORD_ROUTE_PROFILE_UNSPECIFIED, @bulk))

      assert {:error, _} =
               StreamRoute.resolve(contract(@durable, :EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED))
    end
  end

  describe "physical stream isolation" do
    test "bulk and interactive never share a physical stream, and recovery holds its own" do
      {:ok, db} = StreamRoute.resolve(contract(@durable, @bulk))
      {:ok, di} = StreamRoute.resolve(contract(@durable, @interactive))
      {:ok, rec} = StreamRoute.resolve(contract(@recovery, @bulk))
      {:ok, qb} = StreamRoute.resolve_dlq(@bulk, 0)
      {:ok, qi} = StreamRoute.resolve_dlq(@interactive, 0)

      streams = Enum.map([db, di, rec, qb, qi], & &1.expected_stream)

      assert length(Enum.uniq(streams)) == 5,
             "expected five disjoint physical streams, got #{inspect(streams)}"
    end
  end

  describe "partitioning is contract-specific" do
    test "the partition comes from the signed scope, and callers cannot choose it" do
      c = contract(@durable, @bulk, 42)
      {:ok, a} = StreamRoute.resolve(c)

      # A caller-supplied key is ignored: the map is not a suggestion box.
      {:ok, b} = StreamRoute.resolve(Map.put(c, :partition_key, scope(999)))
      assert a.subject == b.subject
      assert a.partition == b.partition
    end

    test "a missing scope is refused rather than routed to partition 0" do
      c = Map.delete(contract(@durable, @bulk), :network_scope_id)
      assert {:error, :partition_key} = StreamRoute.resolve(c)
    end

    test "recovery needs no scope, because it is unpartitioned" do
      c = Map.delete(contract(@recovery, @bulk), :network_scope_id)
      assert {:ok, %ResolvedRoute{partition: nil}} = StreamRoute.resolve(c)
    end

    test "partitions stay in range, are stable, and are not degenerate" do
      keys = for i <- 1..500, do: scope(i)

      for k <- keys do
        p = StreamRoute.partition(k)
        assert p >= 0 and p < StreamRoute.num_partitions()
        assert p == StreamRoute.partition(k)
      end

      # NOT VACUOUS: a hash returning a constant would satisfy range and determinism above.
      spread = keys |> Enum.map(&StreamRoute.partition/1) |> Enum.uniq() |> length()

      assert spread > 32,
             "only #{spread} distinct partitions over 500 keys; the hash is degenerate"
    end

    test "an out-of-range DLQ partition is refused, not formatted into a subject" do
      assert {:error, :partition_out_of_range} =
               StreamRoute.resolve_dlq(@bulk, StreamRoute.num_partitions())

      assert {:error, :partition_out_of_range} = StreamRoute.resolve_dlq(@bulk, -1)
    end
  end

  describe "map version" do
    # EVERY lane, not just one. An earlier version spoofed the version on a durable contract
    # only, which left the recovery branch free to honour a caller-supplied generation -- a
    # mutation that did exactly that survived. Per-branch construction needs per-branch coverage.
    test "no active lane lets a caller override the generation" do
      for {profile, class} <- StreamRoute.active_lanes() do
        c = contract(profile, class)

        {:ok, honest} = StreamRoute.resolve(c)
        assert honest.map_version == StreamRoute.map_version()

        {:ok, spoofed} = StreamRoute.resolve(Map.put(c, :route_map_version, 99))

        assert spoofed.map_version == StreamRoute.map_version(),
               "#{profile}/#{class} honoured a caller-supplied route_map_version"

        assert spoofed == honest,
               "#{profile}/#{class} resolved differently when handed an unrecognised key"
      end
    end

    test "the DLQ carries the active generation and ignores unrecognised input" do
      for class <- [@bulk, @interactive] do
        {:ok, dlq} = StreamRoute.resolve_dlq(class, 1)
        assert dlq.map_version == StreamRoute.map_version()
      end
    end
  end
end
