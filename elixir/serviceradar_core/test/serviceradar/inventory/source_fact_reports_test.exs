defmodule ServiceRadar.Inventory.SourceFactReportsTest do
  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceSourceFact
  alias ServiceRadar.Inventory.SourceFactAuthority
  alias ServiceRadar.Inventory.SourceFactDisagreement
  alias ServiceRadar.Inventory.SourceFacts.Reconciler
  alias ServiceRadar.Repo

  @reported %{"switch_hostname" => "access01.example.com", "port" => "Gi1/0/7"}
  @other %{"switch_hostname" => "access02.example.com", "port" => "Gi1/0/9"}
  @integration_instance Ecto.UUID.generate()

  defp system_actor, do: SystemActor.system(:source_fact_reports_test)

  defp caller(permissions \\ ["devices.source_facts.write"]) do
    %{id: Ecto.UUID.generate(), role: :operator, permissions: MapSet.new(permissions)}
  end

  defp device! do
    unique = System.unique_integer([:positive])

    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:source-fact-reports-#{unique}",
      hostname: "source-fact-reports-#{unique}.test"
    })
    |> Ash.create!(actor: system_actor())
  end

  defp report(actor, device, fact_key, value, source \\ "example-nms") do
    Device
    |> Ash.ActionInput.for_action(:report_source_fact, %{
      device_uid: device.uid,
      fact_key: fact_key,
      source: source,
      value: value
    })
    |> Ash.run_action(actor: actor)
  end

  defp retract(actor, device, fact_key, source \\ "example-nms") do
    Device
    |> Ash.ActionInput.for_action(:retract_source_fact, %{
      device_uid: device.uid,
      fact_key: fact_key,
      source: source
    })
    |> Ash.run_action(actor: actor)
  end

  # The sync path, as an integration's snapshot reaches it.
  defp integration_reports!(device, value) do
    update = %{
      source: "armis",
      source_instance: @integration_instance,
      facts: %{"switch_port_attachment" => value}
    }

    :ok = Reconciler.ingest_resolved([{update, device.uid}])
  end

  defp canonical(device) do
    Repo.one(
      from(d in Device,
        where: d.uid == ^device.uid,
        select: %{switch_port_attachment: d.switch_port_attachment, vlan_uid: d.vlan_uid}
      )
    )
  end

  defp facts(device) do
    Repo.all(
      from(f in DeviceSourceFact,
        where: f.device_uid == ^device.uid,
        select: %{
          source: f.source,
          source_instance: f.source_instance,
          fact_key: f.fact_key,
          present: f.present
        }
      )
    )
  end

  defp open_disagreements(device) do
    Repo.all(
      from(d in SourceFactDisagreement,
        where: d.device_uid == ^device.uid and d.status == "open",
        select: d.values
      )
    )
  end

  setup do
    %{device: device!()}
  end

  test "a sole reported value becomes the canonical attachment", %{device: device} do
    actor = caller()

    assert {:ok, result} = report(actor, device, "switch_port_attachment", @reported)

    assert result.source == "api:example-nms"
    assert result.source_instance == "user:#{actor.id}"
    assert result.fact.present
    assert result.fact.value["port"] == "Gi1/0/7"
    refute result.disagreement_open

    attachment = canonical(device).switch_port_attachment
    assert attachment["switch_hostname"] == "access01.example.com"
    assert attachment["source"] == "api:example-nms"
    assert attachment["source_instance"] == "user:#{actor.id}"
    assert result.canonical == attachment
  end

  test "a value that disagrees with an integration keeps the integration's value and opens a disagreement",
       %{device: device} do
    integration_reports!(device, @other)
    assert canonical(device).switch_port_attachment["source"] == "armis"

    assert {:ok, result} = report(caller(), device, "switch_port_attachment", @reported)

    assert result.disagreement_open
    assert canonical(device).switch_port_attachment["port"] == "Gi1/0/9"

    assert [values] = open_disagreements(device)
    sources = values["sources"] |> Enum.map(& &1["source"]) |> Enum.sort()
    assert sources == ["api:example-nms", "armis"]
  end

  test "a label equal to an integration's source does not take its authority", %{device: device} do
    # An empty instance matches every instance of the source, the broadest row.
    SourceFactAuthority
    |> Ash.Changeset.for_create(:upsert, %{
      source_kind: "integration_source",
      source_ref: @integration_instance,
      source: "armis",
      source_instance: nil,
      fact_key: "switch_port_attachment",
      rank: 1,
      enabled: true
    })
    |> Ash.create!(actor: system_actor())

    integration_reports!(device, @other)

    assert {:ok, result} = report(caller(), device, "switch_port_attachment", @reported, "armis")

    assert result.source == "api:armis"
    assert canonical(device).switch_port_attachment["port"] == "Gi1/0/9"
    assert canonical(device).switch_port_attachment["source"] == "armis"
  end

  test "a caller cannot withdraw another caller's fact", %{device: device} do
    owner = caller()
    other = caller()

    assert {:ok, _result} = report(owner, device, "switch_port_attachment", @reported)
    assert {:ok, result} = retract(other, device, "switch_port_attachment")

    assert result.fact == nil
    assert [%{source_instance: instance, present: true}] = facts(device)
    assert instance == "user:#{owner.id}"
    assert canonical(device).switch_port_attachment["port"] == "Gi1/0/7"
  end

  test "withdrawing the only value behind the canonical attachment clears it", %{device: device} do
    actor = caller()
    assert {:ok, _result} = report(actor, device, "switch_port_attachment", @reported)

    assert {:ok, result} = retract(actor, device, "switch_port_attachment")

    refute result.fact.present
    assert result.canonical == nil
    assert canonical(device).switch_port_attachment == nil
  end

  test "withdrawing keeps a canonical value another source still reports", %{device: device} do
    integration_reports!(device, @reported)
    actor = caller()

    assert {:ok, %{disagreement_open: false}} =
             report(actor, device, "switch_port_attachment", @reported)

    assert {:ok, _result} = retract(actor, device, "switch_port_attachment")

    attachment = canonical(device).switch_port_attachment
    assert attachment["port"] == "Gi1/0/7"
    assert attachment["source"] == "armis"
  end

  test "a report leaves the caller's other facts as they are", %{device: device} do
    actor = caller()
    assert {:ok, _result} = report(actor, device, "vlan_uid", 120)
    assert {:ok, _result} = report(actor, device, "switch_port_attachment", @reported)

    present = for %{present: true, fact_key: key} <- facts(device), do: key
    assert Enum.sort(present) == ["switch_port_attachment", "vlan_uid"]
    assert canonical(device).vlan_uid == "120"
  end

  test "an unreadable value is refused and nothing is written", %{device: device} do
    actor = caller()

    assert {:error, %Invalid{}} =
             report(actor, device, "switch_port_attachment", %{
               "switch_hostname" => "access01.example.com"
             })

    assert {:error, %Invalid{}} = report(actor, device, "vlan_uid", 5000)
    assert {:error, %Invalid{}} = report(actor, device, "owner", "noc")
    assert {:error, %Invalid{}} = report(actor, device, "vlan_uid", 120, "Example NMS")

    assert facts(device) == []
  end

  test "reporting needs devices.source_facts.write", %{device: device} do
    assert {:error, %Forbidden{}} =
             report(caller(["devices.view"]), device, "switch_port_attachment", @reported)

    assert {:error, %Forbidden{}} =
             retract(
               caller(["devices.view", "devices.facts.write"]),
               device,
               "switch_port_attachment"
             )

    assert facts(device) == []
  end

  test "a deleted device takes no facts", %{device: device} do
    {:ok, _deleted} =
      Device.soft_delete(device, "test", "source_fact_reports_test", actor: system_actor())

    assert {:error, %Invalid{}} = report(caller(), device, "switch_port_attachment", @reported)
    assert facts(device) == []
  end
end
