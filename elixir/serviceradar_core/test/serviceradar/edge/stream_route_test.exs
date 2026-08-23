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
    %{
      route_profile: profile,
      traffic_class: class,
      partition_rule: :network_scope_v1,
      partition_coordinates: %{
        network_scope_id: scope(seed),
        authenticated_agent_id: "agent-0",
        spool_id: <<1::128>>
      }
    }
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
      assert {:ok, b} = dlq(@bulk, 3)
      assert {:ok, i} = dlq(@interactive, 3)

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
            {:ok, r} = dlq(c, part)
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
      {:ok, dlq_bulk} = dlq(@bulk, 7)
      {:ok, dlq_inter} = dlq(@interactive, 7)

      refute dlq_bulk.subject == dlq_inter.subject
      refute dlq_bulk.expected_stream == dlq_inter.expected_stream
    end

    test "the DLQ derives class from the contract, so recovery has no DLQ family of its own" do
      # Structural: resolve_dlq takes (source_route, contract). There is no arity that accepts a
      # standalone route profile, so a recovery-specific DLQ cannot be expressed.
      refute function_exported?(StreamRoute, :resolve_dlq, 3)
      assert function_exported?(StreamRoute, :resolve_dlq, 2)
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
      {:ok, qb} = dlq(@bulk, 0)
      {:ok, qi} = dlq(@interactive, 0)

      streams = Enum.map([db, di, rec, qb, qi], & &1.expected_stream)

      assert length(Enum.uniq(streams)) == 5,
             "expected five disjoint physical streams, got #{inspect(streams)}"
    end
  end

  describe "partitioning follows the contract's pinned rule" do
    test "an UNKNOWN rule is refused, never silently partitioned by network scope" do
      # The registry that owns the other rules does not exist yet. Falling back to network scope
      # would route a record by a rule its contract did not pin, landing it on a partition its
      # consumers do not read -- and it would look correct.
      c = Map.put(contract(@durable, @bulk), :partition_rule, :execution_v1)
      assert {:error, :unknown_partition_rule} = StreamRoute.resolve(c)

      c2 = Map.put(contract(@durable, @bulk), :partition_rule, :assignment_run_v1)
      assert {:error, :unknown_partition_rule} = StreamRoute.resolve(c2)
    end

    test "a MISSING rule is refused; there is no default" do
      c = Map.delete(contract(@durable, @bulk), :partition_rule)
      assert {:error, :missing_partition_rule} = StreamRoute.resolve(c)
    end

    test "only the frozen rules are advertised" do
      assert StreamRoute.partition_rules() == [:network_scope_v1]
    end

    test "the key comes from the pinned rule's coordinate, not from any other field" do
      c = contract(@durable, @bulk, 42)
      {:ok, a} = StreamRoute.resolve(c)

      # Unrecognised keys are ignored: the contract is not a suggestion box.
      {:ok, b} = StreamRoute.resolve(Map.put(c, :partition_key, scope(999)))
      assert a.subject == b.subject

      # Changing the RULE'S coordinate does move it.
      {:ok, other} = StreamRoute.resolve(contract(@durable, @bulk, 43))
      refute other.partition == a.partition or other.subject == a.subject
    end

    test "a missing coordinate is refused rather than routed to partition 0" do
      c = contract(@durable, @bulk)

      c =
        Map.put(c, :partition_coordinates, Map.delete(c.partition_coordinates, :network_scope_id))

      assert {:error, :partition_key} = StreamRoute.resolve(c)
    end

    test "recovery needs no partition coordinate, because it is unpartitioned" do
      c = Map.put(contract(@recovery, @bulk), :partition_coordinates, %{})
      assert {:ok, %ResolvedRoute{partition: nil}} = StreamRoute.resolve(c)
    end
  end

  describe "the partition function is frozen by exact vectors" do
    @vectors_path Path.expand("../../fixtures/edge/partition_vectors_v1.txt", __DIR__)
    @external_resource @vectors_path

    defp load_vectors do
      @vectors_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(fn line ->
        [hex, part] = String.split(line, "\t")
        {Base.decode16!(hex, case: :lower), String.to_integer(part)}
      end)
    end

    test "every committed key maps to its committed partition" do
      vectors = load_vectors()

      # NOT VACUOUS: an empty or unreadable file would make the loop below assert nothing.
      assert length(vectors) >= 30, "expected a real corpus, got #{length(vectors)} vectors"

      for {key, expected} <- vectors do
        assert StreamRoute.partition(key) == expected,
               "key #{Base.encode16(key, case: :lower)} moved from partition #{expected} to " <>
                 "#{StreamRoute.partition(key)}. Changing the hash or the partition count " <>
                 "re-places every future record; bump partition_scheme_version deliberately."
      end
    end

    test "the vectors themselves span the space, so they freeze something" do
      spread = load_vectors() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length()
      assert spread > 20, "vectors cover only #{spread} partitions; they would not catch a skew"
    end

    test "the scheme version and partition count are the ones the vectors were cut against" do
      # These three move together. If either constant changes, the vectors above break, and this
      # states the pairing so the reason is obvious rather than archaeological.
      assert StreamRoute.partition_scheme_version() == 1
      assert StreamRoute.num_partitions() == 64
    end

    test "partitions stay in range for arbitrary keys" do
      for i <- 1..500 do
        p = StreamRoute.partition(scope(i))
        assert p >= 0 and p < StreamRoute.num_partitions()
      end
    end
  end

  describe "DLQ provenance is derived from the source, not chosen" do
    test "the DLQ inherits the source partition exactly" do
      c = contract(@durable, @bulk, 42)
      {:ok, source} = StreamRoute.resolve(c)
      {:ok, q} = StreamRoute.resolve_dlq(source, c)

      assert q.partition == source.partition
      assert q.subject == "telemetry.edge-record-dlq.v1.bulk.#{pad(source.partition)}"
    end

    test "a failure cannot be reclassified into the other traffic class" do
      # The class comes from the same verified contract that produced the source route, so a
      # bulk failure cannot be promoted into the interactive reserve on its way to the queue.
      c = contract(@durable, @bulk, 7)
      {:ok, source} = StreamRoute.resolve(c)

      {:ok, q} = StreamRoute.resolve_dlq(source, c)
      assert q.subject =~ "dlq.v1.bulk."

      {:ok, qi} = StreamRoute.resolve_dlq(source, contract(@durable, @interactive, 7))
      assert qi.subject =~ "dlq.v1.interactive."

      # ...and the partition still tracks the SOURCE, not the substituted contract.
      assert qi.partition == source.partition
    end

    test "recovery, having no source partition, uses authenticated agent/spool coordinates" do
      c = contract(@recovery, @bulk)
      {:ok, source} = StreamRoute.resolve(c)
      assert source.partition == nil

      {:ok, q} = StreamRoute.resolve_dlq(source, c)
      assert is_integer(q.partition) and q.partition >= 0
      assert q.partition < StreamRoute.num_partitions()

      # Stable for the same agent/spool, and different for a different spool -- otherwise every
      # recovery failure would pile onto one partition.
      {:ok, again} = StreamRoute.resolve_dlq(source, c)
      assert again.partition == q.partition

      other =
        Map.put(c, :partition_coordinates, %{
          Map.get(c, :partition_coordinates)
          | spool_id: <<9::128>>
        })

      {:ok, q2} = StreamRoute.resolve_dlq(source, other)
      refute q2.partition == q.partition
    end

    test "recovery without agent/spool coordinates is refused" do
      c = contract(@recovery, @bulk)
      {:ok, source} = StreamRoute.resolve(c)
      stripped = Map.put(c, :partition_coordinates, %{})

      assert {:error, :partition_key} = StreamRoute.resolve_dlq(source, stripped)
    end

    test "something that is not a resolved source route is refused" do
      assert {:error, :source_route} =
               StreamRoute.resolve_dlq(%{partition: 3}, contract(@durable, @bulk))
    end
  end

  describe "the two versions are separate" do
    test "every route carries both, and callers cannot override either" do
      for {profile, class} <- StreamRoute.active_lanes() do
        c = contract(profile, class)

        {:ok, honest} = StreamRoute.resolve(c)
        assert honest.placement_version == StreamRoute.placement_version()
        assert honest.partition_scheme_version == StreamRoute.partition_scheme_version()

        spoofed_input =
          c
          |> Map.put(:route_map_version, 99)
          |> Map.put(:placement_version, 99)
          |> Map.put(:partition_scheme_version, 99)

        {:ok, spoofed} = StreamRoute.resolve(spoofed_input)

        assert spoofed == honest,
               "#{profile}/#{class} honoured a caller-supplied version"
      end
    end

    test "the DLQ route carries both versions too" do
      c = contract(@durable, @bulk)
      {:ok, source} = StreamRoute.resolve(c)
      {:ok, q} = StreamRoute.resolve_dlq(source, c)

      assert q.placement_version == StreamRoute.placement_version()
      assert q.partition_scheme_version == StreamRoute.partition_scheme_version()
    end

    test "they are independently readable, so a placement change need not claim a re-partition" do
      # Two distinct accessors, not one value read twice. If these were ever collapsed back into
      # one constant, moving a partition range to a new stream would falsely assert that the key
      # space had been re-partitioned, and vice versa.
      assert is_integer(StreamRoute.placement_version())
      assert is_integer(StreamRoute.partition_scheme_version())

      refute function_exported?(StreamRoute, :map_version, 0),
             "map_version/0 conflated placement with the partition scheme; it must stay split"
    end
  end

  defp pad(p), do: "p" <> String.pad_leading(Integer.to_string(p), 2, "0")

  defp dlq(class, partition) do
    # Builds a source route whose partition is exactly `partition`, then derives the DLQ from it.
    # Tests state the partition they mean; the module still derives it from the source.
    source = %ResolvedRoute{
      subject: "telemetry.edge-record.v1.bulk.#{pad(partition)}",
      partition: partition,
      expected_stream: "TELEMETRY_EDGE_RECORD_V1_BULK",
      placement_version: StreamRoute.placement_version(),
      partition_scheme_version: StreamRoute.partition_scheme_version()
    }

    StreamRoute.resolve_dlq(source, contract(@durable, class))
  end
end
