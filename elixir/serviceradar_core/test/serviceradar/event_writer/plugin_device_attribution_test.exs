defmodule ServiceRadar.EventWriter.PluginDeviceAttributionTest do
  @moduledoc """
  Scope rules of plugin signal device attribution, against an in-memory loader.

  The database-backed wiring through the metrics processor, the events processor
  and alert device resolution is covered by `PluginDeviceAttributionDbTest`.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.PluginDeviceAttribution
  alias ServiceRadar.EventWriter.Processors.Events
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.Observability.MetricEnvelope

  # Invented values only.
  @assignment_id "4b7e2c91-5d3a-4f68-9e1b-a2c7d8f3b615"
  @agent_id "agent-attr-a"
  @partition "part-a"
  @terminal_ref "orbit:ut:ut-a1"
  @terminal_uid "sr:9f2c6e1a-7b4d-4e83-a5c9-3d1b8e6f2a47"
  @foreign_ref "other-orbit:ut:ut-b2"
  @foreign_uid "sr:2d8b5f3e-6a1c-4b97-8e4d-7c3a9f1e5b26"
  @elsewhere_ref "orbit:ut:ut-c3"
  @elsewhere_uid "sr:7e4a1c9d-3b6f-4d25-9a8e-5f2c8b1d6e39"
  @point_time 1_781_222_400_000_000_000

  defmodule Loader do
    @moduledoc false

    @assignment_id "4b7e2c91-5d3a-4f68-9e1b-a2c7d8f3b615"

    # The assignment belongs to agent-attr-a in part-a and declares only "orbit".
    def load_declared_sources(scopes, _actor) do
      Map.new(scopes, fn
        {@assignment_id, "agent-attr-a", "part-a"} = scope -> {scope, ["orbit"]}
        scope -> {scope, []}
      end)
    end

    # A device exists for the foreign source, and one exists for an "orbit"
    # reference only in another partition.
    def lookup_partition(partition, refs, _actor) do
      devices = %{
        {"part-a", "orbit:ut:ut-a1"} => "sr:9f2c6e1a-7b4d-4e83-a5c9-3d1b8e6f2a47",
        {"part-a", "other-orbit:ut:ut-b2"} => "sr:2d8b5f3e-6a1c-4b97-8e4d-7c3a9f1e5b26",
        {"part-b", "orbit:ut:ut-c3"} => "sr:7e4a1c9d-3b6f-4d25-9a8e-5f2c8b1d6e39"
      }

      refs
      |> Enum.map(&{partition, &1})
      |> Enum.filter(&Map.has_key?(devices, &1))
      |> Map.new(&{&1, Map.fetch!(devices, &1)})
    end
  end

  @opts [loader: Loader]

  describe "reference_source/1" do
    test "returns the source prefix of a plugin-scoped reference" do
      assert PluginDeviceAttribution.reference_source(@terminal_ref) == "orbit"
      assert PluginDeviceAttribution.reference_source("orbit.v2:router:r-1") == "orbit.v2"
    end

    test "rejects canonical uids and values without a source prefix" do
      assert PluginDeviceAttribution.reference_source(@terminal_uid) == nil
      assert PluginDeviceAttribution.reference_source("host01") == nil
      assert PluginDeviceAttribution.reference_source("orbit:") == nil
      assert PluginDeviceAttribution.reference_source("Orbit:ut:x") == nil
      assert PluginDeviceAttribution.reference_source(nil) == nil
    end
  end

  describe "metrics" do
    test "a plugin metric naming a discovered device gets its canonical uid" do
      [row] = metric_rows(@terminal_ref)
      assert row.plugin_assignment_id == @assignment_id
      series_key = row.series_key

      [attributed] = PluginDeviceAttribution.attribute_metric_rows([row], @opts)

      assert attributed.device_id == @terminal_uid
      assert attributed.metadata["plugin_device_ref"] == @terminal_ref
      assert attributed.series_key == series_key
      refute Map.has_key?(attributed, :plugin_assignment_id)
    end

    test "a reference with a source the package does not declare is kept as emitted" do
      [row] = metric_rows(@foreign_ref)

      [attributed] = PluginDeviceAttribution.attribute_metric_rows([row], @opts)

      assert attributed.device_id == @foreign_ref
      refute attributed.device_id == @foreign_uid
      refute Map.has_key?(attributed, :plugin_assignment_id)
    end

    test "a device in another partition does not resolve the reference" do
      [row] = metric_rows(@elsewhere_ref)

      [attributed] = PluginDeviceAttribution.attribute_metric_rows([row], @opts)

      assert attributed.device_id == @elsewhere_ref
      refute attributed.device_id == @elsewhere_uid
    end

    test "an assignment of another agent declares nothing" do
      [row] = metric_rows(@terminal_ref, agent_id: "agent-attr-b")

      [attributed] = PluginDeviceAttribution.attribute_metric_rows([row], @opts)

      assert attributed.device_id == @terminal_ref
    end

    test "an sr: uid is not marked and passes through" do
      [row] = metric_rows(@terminal_uid)
      refute Map.has_key?(row, :plugin_assignment_id)

      assert [^row] = PluginDeviceAttribution.attribute_metric_rows([row], @opts)
    end

    test "the emitting plugin is read from the gateway attestation, not guest tags" do
      # A guest can set any metric tag, including producer_id and source.
      spoofed_tags = %{"producer_id" => @assignment_id, "source" => "wasm-plugin"}

      [unattested] =
        metric_rows(@terminal_ref,
          ingest_identity: %IngestIdentity{source: "wasm-plugin", producer_id: @assignment_id},
          tags: spoofed_tags
        )

      [other_source] =
        metric_rows(@terminal_ref,
          ingest_identity: %IngestIdentity{
            source: "native-addon",
            producer_id: @assignment_id,
            attested_by: "gateway-a"
          },
          tags: spoofed_tags
        )

      refute Map.has_key?(unattested, :plugin_assignment_id)
      refute Map.has_key?(other_source, :plugin_assignment_id)

      assert [%{device_id: @terminal_ref}, %{device_id: @terminal_ref}] =
               PluginDeviceAttribution.attribute_metric_rows([unattested, other_source], @opts)
    end

    test "decoding without the option adds no marker" do
      {:ok, [row], 1} = MetricEnvelope.decode_rows_count(metric_batch(@terminal_ref))
      refute Map.has_key?(row, :plugin_assignment_id)
    end
  end

  describe "events" do
    test "a plugin event naming a discovered device gets its canonical uid" do
      [row] = PluginDeviceAttribution.attribute_event_rows([event_row(@terminal_ref)], @opts)

      assert row.device["uid"] == @terminal_uid
      assert row.device["name"] == "terminal a1"
    end

    test "foreign, other-partition and sr: references are kept as emitted" do
      rows = [event_row(@foreign_ref), event_row(@elsewhere_ref), event_row(@terminal_uid)]

      attributed = PluginDeviceAttribution.attribute_event_rows(rows, @opts)

      assert Enum.map(attributed, & &1.device["uid"]) == [
               @foreign_ref,
               @elsewhere_ref,
               @terminal_uid
             ]
    end

    test "an event without the core-set plugin identity is not attributed" do
      row = event_row(@terminal_ref, service_radar: %{"addon_id" => "addon-a"})

      assert [^row] = PluginDeviceAttribution.attribute_event_rows([row], @opts)
      assert PluginDeviceAttribution.attribute_record(row, @opts) == :not_plugin_reference
    end
  end

  describe "attribute_record/2" do
    test "resolves a plugin reference" do
      assert PluginDeviceAttribution.attribute_record(event_row(@terminal_ref), @opts) ==
               {:plugin_reference, @terminal_uid}
    end

    test "an unresolved plugin reference answers nil, whatever else the record carries" do
      record = Map.put(event_row("orbit:ut:ut-unknown"), :agent_id, @agent_id)

      assert PluginDeviceAttribution.attribute_record(record, @opts) == {:plugin_reference, nil}

      assert PluginDeviceAttribution.attribute_record(event_row(@foreign_ref), @opts) ==
               {:plugin_reference, nil}
    end

    test "a canonical device uid is left to ordinary correlation" do
      assert PluginDeviceAttribution.attribute_record(event_row(@terminal_uid), @opts) ==
               :not_plugin_reference
    end
  end

  defp metric_rows(device_id, opts \\ []) do
    {:ok, rows, _count} =
      device_id
      |> metric_batch(opts)
      |> MetricEnvelope.decode_rows_count(plugin_producer: true)

    rows
  end

  defp metric_batch(device_id, opts \\ []) do
    MetricBatch.encode(%MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{
        agent_id: Keyword.get(opts, :agent_id, @agent_id),
        gateway_id: "gateway-a",
        partition: @partition,
        service_name: "plugin-telemetry",
        service_type: "plugin",
        device_id: device_id
      },
      ingest_identity:
        Keyword.get(opts, :ingest_identity, %IngestIdentity{
          source: "wasm-plugin",
          payload_kind: "serviceradar.metric.v1",
          producer_id: @assignment_id,
          producer_kind: "plugin",
          attested_by: "gateway-a"
        }),
      metrics: [
        %Metric{
          name: "terminal_downlink_bps",
          metric_type: "gauge",
          kind: :METRIC_KIND_GAUGE,
          unit: "bps",
          tags:
            opts
            |> Keyword.get(:tags, %{})
            |> Enum.map(fn {key, value} -> %StringMapEntry{key: key, value: value} end),
          points: [%MetricPoint{value: 125.5, observed_at_unix_nano: @point_time}]
        }
      ]
    })
  end

  defp event_row(device_uid, opts \\ []) do
    service_radar =
      Keyword.get(opts, :service_radar, %{
        "plugin_id" => @assignment_id,
        "agent_id" => @agent_id,
        "partition_id" => @partition
      })

    payload = %{
      "id" => Ecto.UUID.generate(),
      "time" => "2026-01-01T00:00:00Z",
      "class_uid" => 1008,
      "category_uid" => 1,
      "type_uid" => 100_801,
      "activity_id" => 1,
      "severity_id" => 3,
      "message" => "terminal obstructed",
      "device" => %{"uid" => device_uid, "name" => "terminal a1"},
      "metadata" => %{"service_radar" => service_radar}
    }

    Events.parse_message(%{
      data: Jason.encode!(payload),
      metadata: %{subject: "events.ocsf.processed"}
    })
  end
end
