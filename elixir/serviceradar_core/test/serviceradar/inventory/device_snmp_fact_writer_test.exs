defmodule ServiceRadar.Inventory.DeviceSNMPFactWriterTest do
  @moduledoc """
  Turning decoded SNMP metric rows into per-device current-state facts.

  Rows here are shaped exactly as `ServiceRadar.Observability.MetricEnvelope`
  emits them, because that is the writer's real input: `metadata["oid"]` is the
  instance OID, `metadata["raw_value"]` is the only representation a string OID
  survives in, and `device_id` has already been resolved upstream.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceSNMPFact
  alias ServiceRadar.Inventory.DeviceSNMPFactWriter
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  require Ash.Query

  @moduletag :integration

  setup do
    actor = SystemActor.system(:device_snmp_fact_writer_test)
    {:ok, device} = create_device(actor)
    %{actor: actor, device: device}
  end

  # The reason the table exists: timeseries_metrics.value is a non-nullable
  # float, so this value has nowhere else to go.
  test "keeps a string reading that the timeseries column cannot hold", %{
    actor: actor,
    device: device
  } do
    :ok =
      DeviceSNMPFactWriter.write_rows([
        row(device.uid,
          metric_name: "node_version",
          oid: ".1.3.6.1.4.1.14823.1.6.1.1.1.1.1.3.0",
          data_type: "string",
          raw_value: "6.11.15",
          value: 0.0
        )
      ])

    assert [fact] = facts(device.uid, actor)
    assert fact.value == "6.11.15"
    assert fact.data_type == "string"
    assert fact.oid_name == "node_version"
  end

  test "falls back to the numeric value when no raw value was sent", %{
    actor: actor,
    device: device
  } do
    :ok =
      DeviceSNMPFactWriter.write_rows([
        row(device.uid, metric_name: "cpu", data_type: "gauge", raw_value: nil, value: 42.0)
      ])

    assert [%{value: "42.0"}] = facts(device.uid, actor)
  end

  # The instance OID already carries the walk index, so walked rows are distinct
  # without any further disambiguation.
  test "stores each walked row separately and records its index", %{
    actor: actor,
    device: device
  } do
    :ok =
      DeviceSNMPFactWriter.write_rows([
        row(device.uid,
          metric_name: "svc",
          oid: ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.2.1",
          data_type: "string",
          raw_value: "radius",
          oid_index: "1"
        ),
        row(device.uid,
          metric_name: "svc",
          oid: ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.2.2",
          data_type: "string",
          raw_value: "tacacs",
          oid_index: "2"
        )
      ])

    facts = facts(device.uid, actor)
    assert length(facts) == 2
    assert facts |> Enum.map(& &1.value) |> Enum.sort() == ["radius", "tacacs"]
    assert facts |> Enum.map(& &1.oid_index) |> Enum.sort() == ["1", "2"]
  end

  # tags["interface_uid"] looks like an equivalent source for the index and is
  # not: for a scalar get on a non-interface OID whose last arc is a positive
  # integer, the agent derives "ifindex:<last arc>" from the OID itself. Reading
  # the index from there would invent one for a reading that has none.
  test "does not mistake a derived interface_uid for a walk index", %{
    actor: actor,
    device: device
  } do
    :ok =
      DeviceSNMPFactWriter.write_rows([
        row(device.uid,
          oid: ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.2.3",
          interface_uid: "ifindex:3",
          oid_index: nil
        )
      ])

    assert [%{oid_index: ""}] = facts(device.uid, actor)
  end

  # A poll replaces the reading. This is a snapshot; the time series is history.
  test "re-polling replaces rather than accumulating", %{actor: actor, device: device} do
    oid = ".1.3.6.1.2.1.1.3.0"

    :ok = DeviceSNMPFactWriter.write_rows([row(device.uid, oid: oid, raw_value: "100")])
    :ok = DeviceSNMPFactWriter.write_rows([row(device.uid, oid: oid, raw_value: "200")])

    assert [%{value: "200"}] = facts(device.uid, actor)
  end

  # One drained batch can carry several polls of the same OID. Without in-batch
  # dedup they upsert over each other in arbitrary order and the older reading
  # can win.
  test "keeps the newest reading when a batch carries several polls of one OID", %{
    actor: actor,
    device: device
  } do
    oid = ".1.3.6.1.2.1.1.3.0"
    older = DateTime.add(DateTime.utc_now(), -60, :second)

    :ok =
      DeviceSNMPFactWriter.write_rows([
        # Oldest FIRST on purpose: taking the head of the group would pick this
        # one, so ordering the list the other way would let a broken dedup pass.
        row(device.uid, oid: oid, raw_value: "oldest", timestamp: older),
        row(device.uid, oid: oid, raw_value: "newest")
      ])

    assert [%{value: "newest"}] = facts(device.uid, actor)
  end

  # device_uid is a foreign key, so an unresolved reading can never be stored.
  # This pins the observable guarantee - it is skipped and the rest of the batch
  # still lands - rather than the mechanism: rows are upserted individually, so
  # removing the pre-filter changes only whether a doomed round trip is attempted.
  test "skips a reading whose device was never resolved", %{actor: actor, device: device} do
    :ok =
      DeviceSNMPFactWriter.write_rows([
        Map.put(row(device.uid, oid: ".1.3.6.1.2.1.1.1.0"), :device_id, nil),
        row(device.uid, oid: ".1.3.6.1.2.1.1.3.0", raw_value: "kept")
      ])

    assert [%{value: "kept"}] = facts(device.uid, actor)
  end

  test "ignores rows that are not SNMP", %{actor: actor, device: device} do
    :ok =
      DeviceSNMPFactWriter.write_rows([
        Map.put(row(device.uid, oid: ".1.3.6.1.2.1.1.1.0"), :metric_type, "sysmon")
      ])

    assert facts(device.uid, actor) == []
  end

  test "ignores an SNMP row carrying no OID", %{actor: actor, device: device} do
    :ok = DeviceSNMPFactWriter.write_rows([row(device.uid, oid: nil)])
    assert facts(device.uid, actor) == []
  end

  test "records the collecting profile id from metadata", %{actor: actor, device: device} do
    profile_id = Ecto.UUID.generate()

    :ok =
      DeviceSNMPFactWriter.write_rows([
        row(device.uid, snmp_profile_id: profile_id, raw_value: "6.11.15")
      ])

    assert [fact] = facts(device.uid, actor)
    assert fact.snmp_profile_id == profile_id
    assert is_nil(fact.plugin_package_id)
  end

  test "fills plugin_package_id from the collecting profile", %{actor: actor, device: device} do
    package = plugin_package(actor)

    {:ok, profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{name: "facts-#{System.unique_integer([:positive])}"})
      |> Ash.Changeset.force_change_attribute(:plugin_package_id, package.id)
      |> Ash.create(actor: actor)

    :ok =
      DeviceSNMPFactWriter.write_rows([
        row(device.uid, snmp_profile_id: profile.id, raw_value: "6.11.15")
      ])

    assert [fact] = facts(device.uid, actor)
    assert fact.snmp_profile_id == profile.id
    assert fact.plugin_package_id == package.id
  end

  defp row(device_uid, opts \\ []) do
    metadata =
      %{}
      |> put_present("oid", Keyword.get(opts, :oid, ".1.3.6.1.2.1.1.3.0"))
      |> put_present("data_type", Keyword.get(opts, :data_type, "gauge"))
      |> put_present("raw_value", Keyword.get(opts, :raw_value, "1"))

    metadata = put_present(metadata, "oid_index", Keyword.get(opts, :oid_index))
    metadata = put_present(metadata, "non_numeric", Keyword.get(opts, :non_numeric))
    metadata = put_present(metadata, "snmp_profile_id", Keyword.get(opts, :snmp_profile_id))
    metadata = put_present(metadata, "plugin_package_id", Keyword.get(opts, :plugin_package_id))

    tags = put_present(%{}, "interface_uid", Keyword.get(opts, :interface_uid))

    %{
      metric_type: "snmp",
      metric_name: Keyword.get(opts, :metric_name, "uptime"),
      device_id: device_uid,
      value: Keyword.get(opts, :value, 1.0),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      metadata: metadata,
      tags: tags
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp create_device(actor) do
    suffix = System.unique_integer([:positive])

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:snmp-fact-writer:#{suffix}",
      name: "clearpass-#{suffix}",
      partition: "default"
    })
    |> Ash.create(actor: actor)
  end

  defp facts(device_uid, actor) do
    {:ok, facts} =
      DeviceSNMPFact
      |> Ash.Query.filter(device_uid == ^device_uid)
      |> Ash.read(actor: actor)

    facts
  end

  defp plugin_package(actor) do
    suffix = System.unique_integer([:positive])
    plugin_id = "snmp-fact-pkg-#{suffix}"
    name = "SNMP Fact Package #{suffix}"

    {:ok, _plugin} =
      Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: name}, actor: actor)
      |> Ash.create()

    {:ok, package} =
      PluginPackage
      |> Ash.Changeset.for_create(:create, %{
        plugin_id: plugin_id,
        name: name,
        version: "0.1.0",
        entrypoint: "run_check",
        runtime: "wasi-preview1",
        outputs: "serviceradar.plugin_result.v1",
        manifest: %{
          "id" => plugin_id,
          "name" => name,
          "version" => "0.1.0",
          "entrypoint" => "run_check",
          "runtime" => "wasi-preview1",
          "outputs" => "serviceradar.plugin_result.v1",
          "capabilities" => ["get_config"],
          "resources" => %{"requested_memory_mb" => 32, "requested_cpu_ms" => 100}
        },
        content_hash: "sha256:snmp-fact-#{suffix}",
        source_type: :upload
      })
      |> Ash.create(actor: actor, domain: ServiceRadar.Plugins)

    package
  end
end
