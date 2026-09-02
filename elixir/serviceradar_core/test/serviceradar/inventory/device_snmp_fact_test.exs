defmodule ServiceRadar.Inventory.DeviceSNMPFactTest do
  @moduledoc """
  SNMP readings that are facts about a device rather than a series to graph.

  The property this table exists for is that `timeseries_metrics.value` is a
  non-nullable float while `string` is a legal SNMP data type, so a version, a
  role or a service name can be polled successfully and then discarded.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceSNMPFact

  require Ash.Query

  @moduletag :integration

  setup do
    actor = SystemActor.system(:device_snmp_fact_test)
    {:ok, device} = create_device(actor)

    %{actor: actor, device: device}
  end

  # The reason the table exists. A float column cannot hold any of these.
  test "stores a string-valued reading", %{actor: actor, device: device} do
    {:ok, fact} =
      create_fact(device.uid, actor, %{
        oid: ".1.3.6.1.4.1.14823.1.6.1.1.1.1.1.3.0",
        oid_name: "node_version",
        data_type: "string",
        value: "6.11.15"
      })

    assert fact.value == "6.11.15"
    assert fact.data_type == "string"
  end

  # A poll replaces the reading rather than appending one. This is a snapshot,
  # not a history - the time series is the history.
  test "re-polling the same OID upserts rather than duplicating", %{
    actor: actor,
    device: device
  } do
    attrs = %{oid: ".1.3.6.1.2.1.1.3.0", oid_name: "uptime", data_type: "gauge", value: "100"}

    {:ok, _} = create_fact(device.uid, actor, attrs)
    {:ok, second} = create_fact(device.uid, actor, %{attrs | value: "200"})

    assert second.value == "200"
    assert [%{value: "200"}] = facts_for(device.uid, actor)
  end

  # oid_index is an empty string rather than NULL precisely so the upsert above
  # works; NULL does not compare equal to NULL in a unique index. Walked rows
  # must still remain distinct from one another.
  test "walked rows stay distinct by index", %{actor: actor, device: device} do
    base = %{oid: ".1.3.6.1.4.1.14823.1.6.1.1.3.1.1.2", oid_name: "svc", data_type: "string"}

    {:ok, _} = create_fact(device.uid, actor, Map.merge(base, %{oid_index: "1", value: "radius"}))
    {:ok, _} = create_fact(device.uid, actor, Map.merge(base, %{oid_index: "2", value: "tacacs"}))

    values = device.uid |> facts_for(actor) |> Enum.map(& &1.value) |> Enum.sort()
    assert values == ["radius", "tacacs"]
  end

  # A fact is a statement about a device. When the device is gone the statement
  # is meaningless, and an orphan keyed to a uid nothing resolves is worse than
  # no row at all.
  #
  # Exercised with a raw DELETE rather than Ash.destroy: Device has no primary
  # destroy action - inventory soft-deletes - so the only thing that removes the
  # row is a hard delete from a cleanup path, and the guarantee under test is
  # the database's ON DELETE CASCADE, not an Ash callback.
  test "facts do not outlive their device", %{actor: actor, device: device} do
    {:ok, _} =
      create_fact(device.uid, actor, %{
        oid: ".1.3.6.1.2.1.1.3.0",
        oid_name: "uptime",
        data_type: "gauge",
        value: "1"
      })

    assert [_fact] = facts_for(device.uid, actor)

    ServiceRadar.Repo.query!("DELETE FROM platform.ocsf_devices WHERE uid = $1", [device.uid])

    assert facts_for(device.uid, actor) == []
  end

  defp create_device(actor) do
    suffix = System.unique_integer([:positive])

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:test-device:#{suffix}",
      name: "clearpass-#{suffix}",
      partition: "default"
    })
    |> Ash.create(actor: actor)
  end

  defp create_fact(device_uid, actor, attrs) do
    DeviceSNMPFact
    |> Ash.Changeset.for_create(
      :create,
      attrs
      |> Map.put(:device_uid, device_uid)
      |> Map.put_new(:collected_at, DateTime.utc_now())
      |> Map.put_new(:oid_index, "")
    )
    |> Ash.create(actor: actor)
  end

  defp facts_for(device_uid, actor) do
    {:ok, facts} =
      DeviceSNMPFact
      |> Ash.Query.filter(device_uid == ^device_uid)
      |> Ash.read(actor: actor)

    facts
  end
end
