defmodule ServiceRadar.Edge.StreamRouteTest do
  @moduledoc """
  Task 4.1 requires a "complete non-overlapping `(traffic_class, route_profile, pNN) -> physical
  stream` map". Completeness and non-overlap are the properties worth testing, so they are
  derived from the enums and the map rather than spot-checked against a hand-written list -- a
  hand list agrees with itself when a member is added and nobody notices.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.StreamRoute

  # Derived from the generated protobuf enums, NOT retyped. A new route profile or traffic class
  # then reaches these tests automatically instead of silently sitting outside them.
  defp route_profiles do
    Serviceradar.Edge.V1.EdgeRecordRouteProfile.mapping() |> Map.keys()
  end

  defp traffic_classes do
    Serviceradar.Edge.V1.EdgeRecordTrafficClass.mapping() |> Map.keys()
  end

  defp specified(atoms) do
    Enum.reject(atoms, &String.ends_with?(Atom.to_string(&1), "_UNSPECIFIED"))
  end

  test "the enum cross-product is exactly the routable set plus the unspecified members" do
    all = for p <- route_profiles(), c <- traffic_classes(), do: {p, c}

    {routable, unroutable} =
      Enum.split_with(all, fn {p, c} -> match?({:ok, _}, StreamRoute.token(p, c)) end)

    assert Enum.sort(routable) == Enum.sort(StreamRoute.routable_lanes()),
           "routable_lanes/0 disagrees with what token/2 actually routes"

    # Every non-routable pair must involve an UNSPECIFIED member. A specified pair that routes
    # nowhere is a hole in a map the spec requires to be complete.
    for {p, c} <- unroutable do
      assert String.ends_with?(Atom.to_string(p), "_UNSPECIFIED") or
               String.ends_with?(Atom.to_string(c), "_UNSPECIFIED"),
             "specified pair #{inspect({p, c})} has no route, so the map is not complete"
    end
  end

  test "every specified pair resolves to a physical stream" do
    for p <- specified(route_profiles()), c <- specified(traffic_classes()) do
      assert {:ok, stream} = StreamRoute.physical_stream(p, c)
      assert stream =~ ~r/^EDGE_[A-Z_]+_V\d+$/, "malformed stream name #{stream}"
    end
  end

  test "bulk and interactive never share a physical stream" do
    for p <- specified(route_profiles()) do
      {:ok, bulk} = StreamRoute.physical_stream(p, :EDGE_RECORD_TRAFFIC_CLASS_BULK)
      {:ok, inter} = StreamRoute.physical_stream(p, :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE)

      if p == :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1 do
        # The documented judgment call: recovery collapses both classes to one lane.
        assert bulk == inter
      else
        refute bulk == inter,
               "#{p} shares one physical stream across traffic classes, so bulk can starve interactive"
      end
    end
  end

  test "data and DLQ streams are disjoint across every lane" do
    data = for {p, c} <- StreamRoute.routable_lanes(), do: elem(StreamRoute.physical_stream(p, c), 1)
    dlq = for {p, c} <- StreamRoute.routable_lanes(), do: elem(StreamRoute.physical_dlq_stream(p, c), 1)

    assert MapSet.disjoint?(MapSet.new(data), MapSet.new(dlq)),
           "a DLQ stream collides with a data stream, so poison would land on live data"
  end

  test "data and DLQ subjects are disjoint across every lane and partition" do
    subjects =
      for {p, c} <- StreamRoute.routable_lanes(),
          part <- 0..(StreamRoute.num_partitions() - 1) do
        {:ok, d} = StreamRoute.data_subject(p, c, part)
        {:ok, q} = StreamRoute.dlq_subject(p, c, part)
        {d, q}
      end

    data = MapSet.new(subjects, &elem(&1, 0))
    dlq = MapSet.new(subjects, &elem(&1, 1))

    assert MapSet.disjoint?(data, dlq)
    # Distinct lanes and partitions must not collapse onto one subject. Recovery's two pairs
    # DO collapse by design, so the expected count discounts them.
    recovery_dupes = StreamRoute.num_partitions()
    assert MapSet.size(data) == length(subjects) - recovery_dupes
  end

  test "partitions stay in range and are stable for the same key" do
    keys = for i <- 1..500, do: :crypto.hash(:sha256, <<i::32>>)

    for k <- keys do
      p = StreamRoute.partition(k)
      assert p >= 0 and p < StreamRoute.num_partitions()
      assert p == StreamRoute.partition(k), "partition/1 is not deterministic"
    end

    # NOT VACUOUS: a hash that always returned 0 would satisfy range and determinism above.
    spread = keys |> Enum.map(&StreamRoute.partition/1) |> Enum.uniq() |> length()
    assert spread > 32, "only #{spread} distinct partitions over 500 keys; the hash is degenerate"
  end

  test "an empty key is routable rather than an error" do
    assert StreamRoute.partition("") == 0
  end

  test "out-of-range partitions are refused, not formatted into a subject" do
    lane = hd(StreamRoute.routable_lanes())
    {p, c} = lane

    assert {:error, :partition_out_of_range} =
             StreamRoute.data_subject(p, c, StreamRoute.num_partitions())

    assert {:error, :partition_out_of_range} = StreamRoute.data_subject(p, c, -1)
    assert {:error, :partition_out_of_range} = StreamRoute.dlq_subject(p, c, 9_999)
  end

  test "unspecified members are unroutable" do
    assert {:error, :unroutable_lane} =
             StreamRoute.token(
               :EDGE_RECORD_ROUTE_PROFILE_UNSPECIFIED,
               :EDGE_RECORD_TRAFFIC_CLASS_BULK
             )

    assert {:error, :unroutable_lane} =
             StreamRoute.token(
               :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
               :EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED
             )

    assert {:error, :unroutable_lane} =
             StreamRoute.token(:EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1, :nonsense)
  end

  test "subjects carry the version, so a scheme change cannot be silent" do
    {p, c} = hd(StreamRoute.routable_lanes())
    {:ok, subject} = StreamRoute.data_subject(p, c, 7)

    assert subject == "sr.edge.v1.records.bulk.p07.v#{StreamRoute.subject_version()}"
  end
end
