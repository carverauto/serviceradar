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

    test "the DLQ families are normative but NOT resolvable yet" do
      # The families exist in the spec. There is deliberately no resolve_dlq/2: the version that
      # existed took the traffic class from a contract supplied alongside the source route, so a
      # bulk failure could be resolved into the interactive DLQ. A DLQ route must be derived from
      # the failure context -- the bounded wrapper, source stream/sequence, error cohort -- and
      # none of that exists yet, so there is nothing to derive one from.
      refute function_exported?(StreamRoute, :resolve_dlq, 2)
      refute function_exported?(StreamRoute, :resolve_dlq, 3)
    end

    test "no subject outside the five normative families is emitted" do
      subjects =
        for {p, c} <- StreamRoute.active_lanes() do
          {:ok, r} = StreamRoute.resolve(contract(p, c))
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
      streams = Enum.map([db, di, rec], & &1.expected_stream)

      assert length(Enum.uniq(streams)) == 3,
             "expected three disjoint data streams, got #{inspect(streams)}"
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

    test "recovery refuses an unknown or missing rule, like every other profile" do
      # Recovery computes no partition, so it previously returned before consulting the rule --
      # which made "every unknown rule is refused" untrue for exactly the lane nobody inspects.
      unknown = Map.put(contract(@recovery, @bulk), :partition_rule, :execution_v1)
      assert {:error, :unknown_partition_rule} = StreamRoute.resolve(unknown)

      missing = Map.delete(contract(@recovery, @bulk), :partition_rule)
      assert {:error, :missing_partition_rule} = StreamRoute.resolve(missing)
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
      # EXACTLY 38 unique rows. `>= 30` let eight disappear without a failure.
      assert length(vectors) == 38, "expected 38 vectors, got #{length(vectors)}"

      assert length(Enum.uniq_by(vectors, &elem(&1, 0))) == 38, "duplicate keys in the corpus"

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

  describe "the RULE is frozen, not merely the hash" do
    @route_vectors_path Path.expand("../../fixtures/edge/route_vectors_v1.txt", __DIR__)
    @external_resource @route_vectors_path

    defp load_route_vectors do
      @route_vectors_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(fn line ->
        [profile, cls, scope_hex, agent, spool_hex, subject, part, stream, pv, sv] =
          String.split(line, "\t")

        %{
          profile:
            case profile do
              "durable" -> @durable
              "recovery" -> @recovery
            end,
          class:
            case cls do
              "bulk" -> @bulk
              "interactive" -> @interactive
            end,
          scope: Base.decode16!(scope_hex, case: :lower),
          agent: agent,
          spool: Base.decode16!(spool_hex, case: :lower),
          subject: subject,
          # The literal `nil`, never 0 -- recovery is unpartitioned and zero is a real partition.
          partition: if(part == "nil", do: nil, else: String.to_integer(part)),
          expected_stream: stream,
          placement_version: String.to_integer(pv),
          partition_scheme_version: String.to_integer(sv)
        }
      end)
    end

    defp resolve_vector(v) do
      StreamRoute.resolve(%{
        route_profile: v.profile,
        traffic_class: v.class,
        partition_rule: :network_scope_v1,
        partition_coordinates: %{
          network_scope_id: v.scope,
          authenticated_agent_id: v.agent,
          spool_id: v.spool
        }
      })
    end

    test "the corpus is exactly 16 UNIQUE rows spanning the space" do
      vectors = load_route_vectors()

      # Bounds the SET, not just its size. Replacing all 16 rows with copies of the first
      # satisfied a length check while freezing nothing.
      assert length(vectors) == 20, "expected 20 route vectors, got #{length(vectors)}"
      assert length(Enum.uniq(vectors)) == 20, "duplicate rows in the route corpus"

      durable = Enum.filter(vectors, &(&1.profile == @durable))
      recovery = Enum.filter(vectors, &(&1.profile == @recovery))

      # BOTH profiles are bound. Recovery's versioned tuple was previously unbound, so a
      # placement or version change on that lane would not have been caught here.
      assert length(durable) == 16, "durable rows: #{length(durable)}"
      assert length(recovery) == 4, "recovery rows: #{length(recovery)}"

      assert length(Enum.uniq_by(durable, & &1.partition)) > 8,
             "the durable corpus barely spans the partition space, so it would not catch a shift"

      assert length(Enum.uniq_by(vectors, & &1.class)) == 2, "the corpus covers only one class"

      # Recovery collapses to ONE subject across both classes and every scope, and its partition
      # is nil in every row.
      assert length(Enum.uniq_by(recovery, & &1.subject)) == 1
      assert Enum.all?(recovery, &(&1.partition == nil))
      assert length(Enum.uniq_by(recovery, & &1.class)) == 2
    end

    test "every vector resolves to its committed COMPLETE route, field for field" do
      # The whole tuple. Asserting only the subject let two mutants through: shifting
      # route.partition by one while keeping the subject suffix, and renaming both physical
      # streams without incrementing placement_version.
      for v <- load_route_vectors() do
        assert {:ok, route} = resolve_vector(v)

        assert route.subject == v.subject
        assert route.partition == v.partition
        assert route.expected_stream == v.expected_stream
        assert route.placement_version == v.placement_version
        assert route.partition_scheme_version == v.partition_scheme_version
      end
    end

    test "the resolved tuple SET is exactly the committed tuple set" do
      resolved =
        for v <- load_route_vectors() do
          {:ok, r} = resolve_vector(v)

          {r.subject, r.partition, r.expected_stream, r.placement_version,
           r.partition_scheme_version}
        end

      committed =
        for v <- load_route_vectors() do
          {v.subject, v.partition, v.expected_stream, v.placement_version,
           v.partition_scheme_version}
        end

      assert Enum.sort(resolved) == Enum.sort(committed)

      assert length(Enum.uniq(committed)) > 8, "the committed tuple set is nearly degenerate"
    end

    test "the transcript is the SCOPE ALONE: agent and spool do not move the route" do
      # The key->partition vectors call partition/1 with preassembled bytes, so a rule hashing
      # `scope <> agent_id` reproduces them exactly while routing every record elsewhere. Here
      # the components are supplied separately.
      vectors = Enum.filter(load_route_vectors(), &(&1.profile == @durable))
      grouped = Enum.group_by(vectors, &{&1.class, &1.scope})
      shared = Enum.filter(grouped, fn {_k, rows} -> length(rows) > 1 end)

      assert shared != [], "the corpus must contain one scope under several agent/spool pairs"

      for {_key, rows} <- shared do
        routes =
          rows
          |> Enum.map(fn v ->
            {:ok, r} = resolve_vector(v)
            {r.subject, r.partition}
          end)
          |> Enum.uniq()

        assert length(routes) == 1,
               "one scope produced #{length(routes)} routes, so the transcript is not the scope alone"
      end
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
end
