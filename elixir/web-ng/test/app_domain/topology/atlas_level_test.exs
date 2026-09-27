defmodule ServiceRadarWebNG.Topology.AtlasLevelTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.Atlas
  alias ServiceRadarWebNG.Topology.AtlasLevel

  @moduletag :db_free

  test "inventory-only changes revise the affected displayed level without moving geometry" do
    {global, first, second} = selected_levels()
    devices = devices()
    assert {:ok, original} = AtlasLevel.enrich(first, devices)
    assert {:ok, other} = AtlasLevel.enrich(second, devices)
    assert {:ok, overview} = AtlasLevel.enrich(global, devices)
    id = hd(first.nodes).id
    original_device = Map.fetch!(devices, id)

    for patch <- [
          %{last_seen_time: ~U[2025-01-01 00:01:00Z]},
          %{name: "Renamed synthetic router"},
          %{is_available: false},
          %{metadata: %{"latitude" => "12.5", "longitude" => "34.5"}}
        ] do
      changed = Map.put(devices, id, Map.merge(original_device, patch))
      assert {:ok, refreshed} = AtlasLevel.enrich(first, changed)
      assert refreshed.revision != original.revision
      assert refreshed.structure_revision == original.structure_revision
      assert Enum.map(refreshed.nodes, & &1.id) == Enum.map(original.nodes, & &1.id)
      assert {:ok, ^other} = AtlasLevel.enrich(second, changed)
      assert {:ok, ^overview} = AtlasLevel.enrich(global, changed)
    end

    changed_type = put_in(devices, [id, :type], "switch")
    assert {:ok, changed} = AtlasLevel.enrich(first, changed_type)
    assert changed.structure_revision != original.structure_revision
    assert Enum.find(changed.nodes, &(&1.id == id)).details.type == "switch"

    projected = put_in(devices, [id, :metadata], %{"identity_source" => "endpoint_attachment_projection"})
    assert {:ok, changed} = AtlasLevel.enrich(first, projected)
    assert changed.structure_revision != original.structure_revision
    assert Enum.find(changed.nodes, &(&1.id == id)).details.identity_source == "endpoint_attachment_projection"

    bookkeeping = put_in(devices, [id, :modified_time], ~U[2025-01-02 00:00:00Z])
    assert {:ok, ^original} = AtlasLevel.enrich(first, bookkeeping)
  end

  test "final revision hashes displayed values independently of canonical generation and selection revision" do
    {_global, first, _second} = selected_levels()
    assert {:ok, original} = AtlasLevel.enrich(first, devices())

    next_source = %{first | canonical_revision: first.canonical_revision + 1, revision: first.revision + 1}
    assert {:ok, refreshed} = AtlasLevel.enrich(next_source, devices())
    assert refreshed.revision == original.revision
    assert refreshed.structure_revision == original.structure_revision
    assert refreshed.canonical_revision != original.canonical_revision

    changed_relation = update_in(first.edges, fn [edge] -> [Map.put(edge, :flow_pps, 27)] end)
    assert {:ok, telemetry} = AtlasLevel.enrich(changed_relation, devices())
    assert telemetry.revision != original.revision
    assert telemetry.structure_revision == original.structure_revision
    assert original.revision < 4_503_599_627_370_496
  end

  test "selected nodes keep identity while inventory text is bounded and camera details remain unknown" do
    {_global, first, _second} = selected_levels()
    id = hd(first.nodes).id

    inventory =
      Map.put(devices(), id, %{
        uid: id,
        name: String.duplicate("é", 300),
        hostname: String.duplicate("x", 800),
        type: "router",
        model: <<255, 254>>,
        metadata: %{"secret" => "never projected"}
      })

    assert {:ok, enriched} = AtlasLevel.enrich(first, inventory)
    node = Enum.find(enriched.nodes, &(&1.id == id))
    assert node.id == id
    assert node.details.device_uid == id
    assert String.valid?(node.label)
    assert byte_size(node.label) == 256
    assert byte_size(node.details.hostname) == 256
    refute Map.has_key?(node.details, :camera_capable)
    refute Map.has_key?(node.details, :camera_streams)
    refute Map.has_key?(node.details, :secret)
    assert enriched.deferred_details == ["camera"]
    assert length(enriched.nodes) == length(first.nodes)
    assert length(enriched.edges) == length(first.edges)

    assert {:ok, missing} = AtlasLevel.enrich(first, %{})
    assert Enum.all?(missing.nodes, &(&1.label == &1.id and &1.inventory_present == false))

    blank = Map.put(inventory, id, %{uid: id, name: "   "})
    assert {:ok, normalized} = AtlasLevel.enrich(first, blank)
    assert Enum.find(normalized.nodes, &(&1.id == id)).label == id
  end

  test "unbounded relation metadata is rejected before a level can be delivered" do
    {_global, first, _second} = selected_levels()

    oversized =
      update_in(first.edges, fn [edge] ->
        [Map.put(edge, :metadata, %{note: String.duplicate("x", 1_048_576)})]
      end)

    assert {:error, :payload_too_large} = AtlasLevel.enrich(oversized, devices())

    malformed = update_in(first.edges, fn [edge] -> [Map.put(edge, :protocol, <<255>>)] end)
    assert {:error, :invalid_level_content} = AtlasLevel.enrich(malformed, devices())
  end

  defp selected_levels do
    nodes = Enum.map(1..4, &%{id: "sr:synthetic-#{&1}", label: "Graph node #{&1}"})

    edges = [
      %{id: "link-1", source: "sr:synthetic-1", target: "sr:synthetic-2", evidence_class: "direct"},
      %{id: "link-2", source: "sr:synthetic-3", target: "sr:synthetic-4", evidence_class: "direct"}
    ]

    {:ok, index} = Atlas.build(nodes, edges)
    {:ok, global} = Atlas.fetch(index)
    [first, second] = Enum.map(global.nodes, & &1.child_level_id)
    {:ok, first} = Atlas.fetch(index, first)
    {:ok, second} = Atlas.fetch(index, second)

    {Map.put(global, :canonical_revision, index.revision), Map.put(first, :canonical_revision, index.revision),
     Map.put(second, :canonical_revision, index.revision)}
  end

  defp devices do
    Map.new(1..4, fn number ->
      id = "sr:synthetic-#{number}"

      {id,
       %{
         uid: id,
         name: "Synthetic router #{number}",
         hostname: "host#{number}.example.com",
         ip: "192.0.2.#{number}",
         type: "router",
         type_id: 12,
         is_available: true,
         last_seen_time: ~U[2025-01-01 00:00:00Z],
         modified_time: ~U[2025-01-01 00:00:00Z],
         metadata: %{}
       }}
    end)
  end
end
