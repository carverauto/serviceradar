defmodule ServiceRadar.EventWriter.PluginDeviceAttributionDbTest do
  @moduledoc """
  Plugin signal device attribution end to end against the database: a real
  approved package declaring an inventory source, a real assignment bound to an
  agent and partition, and a device carrying the `integration_id` the plugin
  names -- through the metrics processor, the events processor and alert device
  resolution.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.Processors.Events
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias ServiceRadar.Observability.PluginResultRepairAssignmentSupport
  alias ServiceRadar.Observability.StatefulAlertEngine.AlertLifecycle
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query

  @moduletag :integration

  @source "orbit"
  @point_time 1_781_222_400_000_000_000

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:plugin_device_attribution_test)
    unique = System.unique_integer([:positive])
    agent_id = "agent-attr-#{unique}"
    partition = "part-attr-#{unique}"

    package = create_package!(actor, "orbit-cloud-#{unique}", [@source])

    assignment =
      PluginResultRepairAssignmentSupport.create_repair_assignment_for_package!(
        %{agent_id: agent_id, partition: partition, service_name: "plugin-telemetry"},
        package
      )

    # The host the plugin runs on. An unresolved reference must never land here.
    agent_device = create_device!(actor, partition)
    create_agent!(actor, agent_id, agent_device.uid)

    terminal_ref = "#{@source}:ut:ut-#{unique}"
    terminal = create_device!(actor, partition)
    register_integration_id!(actor, terminal.uid, terminal_ref, partition)

    # Exercise attribution with Device's default keyset pagination, not a list
    # returned by a custom loader. Each test uses fresh, uncached references.
    terminal_uid = terminal.uid

    assert %Ash.Page.Keyset{results: [%Device{uid: ^terminal_uid}], more?: false} =
             Device
             |> Ash.Query.for_read(:read, %{include_deleted: false})
             |> Ash.Query.filter(uid == ^terminal_uid)
             |> Ash.read!(actor: actor)

    %{
      actor: actor,
      unique: unique,
      agent_id: agent_id,
      partition: partition,
      assignment_id: to_string(assignment.id),
      agent_device: agent_device,
      terminal: terminal,
      terminal_ref: terminal_ref
    }
  end

  test "a plugin metric is stored against the discovered device", ctx do
    [row] = metric_rows(ctx, ctx.terminal_ref)

    assert row.device_id == ctx.terminal.uid
    assert row.metadata["plugin_device_ref"] == ctx.terminal_ref
    refute Map.has_key?(row, :plugin_assignment_id)
  end

  test "a plugin event is stored against the discovered device", ctx do
    [row] = Events.build_rows([event_message(ctx, ctx.terminal_ref)])

    assert row.device["uid"] == ctx.terminal.uid
  end

  test "an alert from a plugin event is attributed to the discovered device", ctx do
    # The alert path resolves the reference itself too, for a record that was
    # not attributed at ingest, before event ingestion can populate the cache.
    unattributed = Events.parse_message(event_message(ctx, ctx.terminal_ref))
    assert unattributed.device["uid"] == ctx.terminal_ref
    assert AlertLifecycle.resolved_device_uid(unattributed) == ctx.terminal.uid

    [stored] = Events.build_rows([event_message(ctx, ctx.terminal_ref)])
    assert AlertLifecycle.resolved_device_uid(stored) == ctx.terminal.uid
  end

  test "a reference with an undeclared source prefix is not resolved", ctx do
    foreign_ref = "other-orbit:ut:ut-#{ctx.unique}"
    foreign = create_device!(ctx.actor, ctx.partition)
    register_integration_id!(ctx.actor, foreign.uid, foreign_ref, ctx.partition)

    [metric] = metric_rows(ctx, foreign_ref)
    [event] = Events.build_rows([event_message(ctx, foreign_ref)])

    assert metric.device_id == foreign_ref
    assert event.device["uid"] == foreign_ref
    assert AlertLifecycle.resolved_device_uid(record_with_agent(event, ctx)) == nil
  end

  test "an unresolved reference is stored as emitted and not attributed to the agent", ctx do
    unknown_ref = "#{@source}:ut:ut-missing-#{ctx.unique}"

    [metric] = metric_rows(ctx, unknown_ref)
    [event] = Events.build_rows([event_message(ctx, unknown_ref)])

    assert metric.device_id == unknown_ref
    assert event.device["uid"] == unknown_ref

    # Event rows carry no top-level agent_id today; records that do (and the
    # correlation it drives) must still not fall back to the agent's device.
    assert AlertLifecycle.resolved_device_uid(record_with_agent(event, ctx)) == nil

    refute AlertLifecycle.resolved_device_uid(record_with_agent(event, ctx)) ==
             ctx.agent_device.uid
  end

  test "a device carrying the reference in another partition does not match", ctx do
    elsewhere_ref = "#{@source}:ut:ut-elsewhere-#{ctx.unique}"
    elsewhere = create_device!(ctx.actor, "other-part-#{ctx.unique}")
    register_integration_id!(ctx.actor, elsewhere.uid, elsewhere_ref, "other-part-#{ctx.unique}")

    [metric] = metric_rows(ctx, elsewhere_ref)
    [event] = Events.build_rows([event_message(ctx, elsewhere_ref)])

    assert metric.device_id == elsewhere_ref
    assert event.device["uid"] == elsewhere_ref
  end

  test "an sr: device uid passes through unchanged", ctx do
    [metric] = metric_rows(ctx, ctx.terminal.uid)
    [event] = Events.build_rows([event_message(ctx, ctx.terminal.uid)])

    assert metric.device_id == ctx.terminal.uid
    refute Map.has_key?(metric.metadata, "plugin_device_ref")
    assert event.device["uid"] == ctx.terminal.uid
    assert AlertLifecycle.resolved_device_uid(event) == ctx.terminal.uid
  end

  test "a metric with no device id is still backfilled by target IP", ctx do
    ip = unique_ip()
    polled = create_device!(ctx.actor, "default", ip: ip)

    [row] =
      ctx
      |> metric_message(nil,
        ingest_identity: %IngestIdentity{
          source: "snmp-metrics",
          payload_kind: "serviceradar.metric.v1",
          producer_id: ctx.agent_id,
          producer_kind: "agent",
          attested_by: "gateway-attr"
        },
        target_device_ip: ip
      )
      |> List.wrap()
      |> Metrics.decode_batch()
      |> elem(0)
      |> Metrics.attribute_device_ids()

    assert row.device_id == polled.uid
  end

  defp metric_rows(ctx, device_id) do
    {rows, 0} = Metrics.decode_batch([metric_message(ctx, device_id)])
    Metrics.attribute_device_ids(rows)
  end

  defp metric_message(ctx, device_id, opts \\ []) do
    batch = %MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{
        agent_id: ctx.agent_id,
        gateway_id: "gateway-attr",
        partition: ctx.partition,
        service_name: "plugin-telemetry",
        service_type: "plugin",
        device_id: device_id || "",
        target_device_ip: Keyword.get(opts, :target_device_ip, "")
      },
      ingest_identity:
        Keyword.get(opts, :ingest_identity, %IngestIdentity{
          source: "wasm-plugin",
          payload_kind: "serviceradar.metric.v1",
          producer_id: ctx.assignment_id,
          producer_kind: "plugin",
          attested_by: "gateway-attr"
        }),
      metrics: [
        %Metric{
          name: "terminal_downlink_bps",
          metric_type: "gauge",
          kind: :METRIC_KIND_GAUGE,
          unit: "bps",
          points: [%MetricPoint{value: 125.5, observed_at_unix_nano: @point_time}]
        }
      ]
    }

    %{
      data: MetricBatch.encode(batch),
      metadata: %{subject: "metrics.timeseries.gauge.terminal_downlink_bps"}
    }
  end

  defp event_message(ctx, device_uid) do
    payload = %{
      "id" => Ecto.UUID.generate(),
      "time" => "2026-01-01T00:00:00Z",
      "class_uid" => 1008,
      "category_uid" => 1,
      "type_uid" => 100_801,
      "activity_id" => 1,
      "severity_id" => 3,
      "message" => "terminal obstructed",
      "device" => %{"uid" => device_uid, "name" => "terminal"},
      "metadata" => %{
        "service_radar" => %{
          "plugin_id" => ctx.assignment_id,
          "agent_id" => ctx.agent_id,
          "partition_id" => ctx.partition
        }
      }
    }

    %{data: Jason.encode!(payload), metadata: %{subject: "events.ocsf.processed"}}
  end

  defp record_with_agent(row, ctx) do
    row
    |> Map.put(:agent_id, ctx.agent_id)
    |> Map.put(:partition, ctx.partition)
  end

  defp create_package!(actor, plugin_id, sources) do
    name = "Orbit cloud #{plugin_id}"

    Plugin
    |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: name}, actor: actor)
    |> Ash.create!(domain: ServiceRadar.Plugins)

    manifest = %{
      "id" => plugin_id,
      "name" => name,
      "version" => "1.0.0",
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["submit_result"],
      "resources" => %{
        "requested_memory_mb" => 32,
        "requested_cpu_ms" => 100,
        "max_open_connections" => 1
      },
      "integrations" => %{
        "inventory_sources" =>
          Enum.map(
            sources,
            &%{"source" => &1, "label" => "#{&1} inventory", "metadata_fields" => []}
          )
      }
    }

    {:ok, package, _notifications} =
      PluginPackage
      |> Ash.Changeset.for_create(
        :create,
        %{
          plugin_id: plugin_id,
          name: name,
          version: "1.0.0",
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          content_hash: "sha256:#{plugin_id}-1.0.0",
          source_type: :upload
        },
        actor: actor
      )
      |> Ash.create(domain: ServiceRadar.Plugins, return_notifications?: true)

    {:ok, package, _notifications} =
      package
      |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
      |> Ash.update(domain: ServiceRadar.Plugins, return_notifications?: true)

    package
  end

  defp create_device!(actor, partition, opts \\ []) do
    uid = "sr:" <> Ecto.UUID.generate()
    now = DateTime.utc_now()

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        hostname: "device-#{System.unique_integer([:positive])}.example.com",
        ip: Keyword.get(opts, :ip),
        partition: partition,
        type_id: 0,
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp register_integration_id!(actor, device_uid, value, partition) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(
      :register,
      %{
        device_id: device_uid,
        identifier_type: :integration_id,
        identifier_value: value,
        partition: partition,
        confidence: :strong,
        source: "plugin_device_attribution_test"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_agent!(actor, agent_id, device_uid) do
    Agent
    |> Ash.Changeset.for_create(
      :register_connected,
      %{uid: agent_id, name: agent_id, type_id: 0, device_uid: device_uid, capabilities: []},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  # A random IPv6 documentation address, already in canonical text form (every
  # group has four digits, so nothing compresses differently).
  defp unique_ip do
    groups =
      Enum.map_join(1..3, ":", fn _index ->
        (0x1000 + :rand.uniform(0xEFFF) - 1) |> Integer.to_string(16) |> String.downcase()
      end)

    "2001:db8::" <> groups
  end
end
