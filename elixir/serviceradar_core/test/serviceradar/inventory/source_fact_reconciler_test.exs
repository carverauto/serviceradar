defmodule ServiceRadar.Inventory.SourceFactReconcilerTest do
  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceSourceFact
  alias ServiceRadar.Inventory.SourceFactAuthority
  alias ServiceRadar.Inventory.SourceFacts
  alias ServiceRadar.Inventory.SourceFacts.Reconciler
  alias ServiceRadar.Repo

  @integration_port %{"switch_hostname" => "access01.example.com", "port" => "Gi1/0/7"}
  @plugin_port %{"switch_hostname" => "access02.example.com", "port" => "Gi1/0/9"}

  defp system_actor, do: SystemActor.system(:source_fact_reconciler_test)

  defp device! do
    unique = System.unique_integer([:positive])

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:source-fact-reconciler-#{unique}",
      hostname: "source-fact-reconciler-#{unique}.test"
    })
    |> Ash.create!(actor: system_actor())
  end

  # An integration sync update as the ingestor hands it over: the integration source's
  # id travels in metadata.sync_service_id, and there is no explicit source_instance.
  defp integration_update(integration_id, value) do
    %{
      source: "armis",
      metadata: %{"sync_service_id" => integration_id},
      facts: %{"switch_port_attachment" => value}
    }
  end

  defp plugin_update(value) do
    %{
      source: "example-plugin",
      source_instance: "assignment-1",
      facts: %{"switch_port_attachment" => value}
    }
  end

  defp ingest!(device, update), do: :ok = Reconciler.ingest_resolved([{update, device.uid}])

  defp facts(device) do
    Repo.all(
      from(f in DeviceSourceFact,
        where: f.device_uid == ^device.uid,
        select: %{source: f.source, source_instance: f.source_instance, present: f.present}
      )
    )
  end

  defp canonical(device) do
    Repo.one(from(d in Device, where: d.uid == ^device.uid, select: d.switch_port_attachment))
  end

  defp enable_authority!(integration_id) do
    SourceFactAuthority
    |> Ash.Changeset.for_create(:upsert, %{
      source_kind: "integration_source",
      source_ref: integration_id,
      source: "armis",
      source_instance: integration_id,
      fact_key: "switch_port_attachment",
      rank: 1,
      enabled: true
    })
    |> Ash.create!(actor: system_actor())
  end

  # A row as the reconciler stored it before an absent instance read as absent.
  defp insert_legacy_fact!(device, source, value) do
    [fact] = SourceFacts.parse_explicit_facts(%{"switch_port_attachment" => value})
    now = DateTime.utc_now()

    Repo.insert_all(
      "device_source_facts",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          device_uid: device.uid,
          source: source,
          source_instance: "nil",
          fact_key: fact.fact_key,
          compare_hash: fact.compare_hash,
          value: fact.value,
          raw: fact.raw,
          present: true,
          observed_at: now,
          inserted_at: now,
          updated_at: now
        }
      ],
      prefix: "platform"
    )
  end

  setup do
    %{device: device!(), integration_id: Ecto.UUID.generate()}
  end

  test "an integration's facts are stored under its integration source id", %{
    device: device,
    integration_id: integration_id
  } do
    ingest!(device, integration_update(integration_id, @integration_port))

    assert [%{source: "armis", source_instance: ^integration_id, present: true}] = facts(device)
    assert canonical(device)["source_instance"] == integration_id
  end

  test "an enabled integration authority wins a disagreement", %{
    device: device,
    integration_id: integration_id
  } do
    enable_authority!(integration_id)
    ingest!(device, plugin_update(@plugin_port))
    assert canonical(device)["port"] == "Gi1/0/9"

    ingest!(device, integration_update(integration_id, @integration_port))

    attachment = canonical(device)
    assert attachment["port"] == "Gi1/0/7"
    assert attachment["source"] == "armis"
  end

  test "a source's legacy rows are retired once it reports under its real instance", %{
    device: device,
    integration_id: integration_id
  } do
    insert_legacy_fact!(device, "armis", @plugin_port)

    ingest!(device, integration_update(integration_id, @integration_port))

    by_instance = Map.new(facts(device), &{&1.source_instance, &1.present})
    assert by_instance == %{"nil" => false, integration_id => true}
    assert canonical(device)["port"] == "Gi1/0/7"
    assert canonical(device)["source_instance"] == integration_id
  end

  test "another source's legacy rows are left alone", %{
    device: device,
    integration_id: integration_id
  } do
    insert_legacy_fact!(device, "example-plugin", @plugin_port)

    ingest!(device, integration_update(integration_id, @integration_port))

    assert %{source_instance: "nil", present: true} =
             Enum.find(facts(device), &(&1.source == "example-plugin"))
  end

  test "the last update of a source in a batch decides each fact", %{device: device} do
    reported = plugin_update(@plugin_port)
    omitted = Map.delete(reported, :facts)

    :ok = Reconciler.ingest_resolved([{reported, device.uid}, {omitted, device.uid}])
    assert [%{source: "example-plugin", present: false}] = facts(device)

    :ok = Reconciler.ingest_resolved([{omitted, device.uid}, {reported, device.uid}])
    assert [%{source: "example-plugin", present: true}] = facts(device)
    assert canonical(device)["port"] == "Gi1/0/9"
  end

  # A Wi-Fi or Proxmox result sends every device it reports through here. Statements per
  # device put a large result over the plugin-result lane's execution budget.
  test "a batch costs the same statements whatever its device count" do
    small = Enum.map(1..2, fn _ -> device!() end)
    large = Enum.map(1..12, fn _ -> device!() end)

    assert statement_count(small) == statement_count(large)
  end

  defp statement_count(devices) do
    update = %{source: "example-plugin", source_instance: "assignment-1"}
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:service_radar, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, :statement)
      end,
      nil
    )

    try do
      :ok = Reconciler.ingest_resolved(Enum.map(devices, &{update, &1.uid}))
    after
      :telemetry.detach(handler_id)
    end

    count_statements(0)
  end

  defp count_statements(count) do
    receive do
      :statement -> count_statements(count + 1)
    after
      0 -> count
    end
  end
end
