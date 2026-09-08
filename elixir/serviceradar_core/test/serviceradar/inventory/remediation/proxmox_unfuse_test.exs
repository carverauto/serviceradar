defmodule ServiceRadar.Inventory.Remediation.ProxmoxUnfuseTest do
  @moduledoc """
  DB-backed coverage for the `proxmox-unfuse` step (GitHub #4051): a fused
  device (v2 ids spanning clusters) is detected and split-planned with its
  earliest cluster surviving, while single-cluster devices and
  unattributable-MAC candidates are skipped fail-closed.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Remediation.ProxmoxUnfuse
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:proxmox_unfuse_test)}
  end

  test "dry run detects and plans the split; earliest cluster survives", %{actor: actor} do
    seed = System.unique_integer([:positive])
    farm_v2 = "proxmox:v2:farm#{seed}:vm:113"
    tonka_v2 = "proxmox:v2:tonka#{seed}:vm:117"
    farm_mac = "AA" <> String.pad_leading(Integer.to_string(seed, 16), 10, "0")
    tonka_mac = "BB" <> String.pad_leading(Integer.to_string(seed, 16), 10, "0")

    {:ok, fused} = create_device(actor, %{hostname: "k8s-cp3-worker1"})
    {:ok, _} = seed_identifier(actor, fused.uid, :integration_id, farm_v2, "proxmox-farm")
    {:ok, _} = seed_identifier(actor, fused.uid, :integration_id, tonka_v2, "proxmox-tonka")
    {:ok, _} = seed_identifier(actor, fused.uid, :mac, farm_mac, "proxmox-farm")
    {:ok, _} = seed_identifier(actor, fused.uid, :mac, tonka_mac, "proxmox-tonka")

    report = ProxmoxUnfuse.run(:dry_run, [], nil, actor)

    assert report.candidate_devices >= 1
    assert report.detected_planned_splits >= 1

    plan =
      Enum.find(report.detected_split_plan, &(&1.device_uid == fused.uid))

    assert plan.survivor_cluster == "farm#{seed}"
    assert plan.new_device_count == 1
    assert plan.execution_eligible == false

    [split] = plan.new_devices
    assert split.cluster == "tonka#{seed}"
    assert split.v2_values == [tonka_v2]
    assert split.identifiers == 2
    assert [%{value: ^tonka_mac, source_id: "proxmox-tonka"}] = split.macs
  end

  # Single-cluster devices never reach the planner (detection requires a
  # cluster span); that skip is pinned at unit level in decisions_test.exs.
  test "candidates with unattributable MACs are skipped fail-closed", %{actor: actor} do
    seed = System.unique_integer([:positive])

    {:ok, shared} = create_device(actor, %{hostname: "shared-src-#{seed}"})

    {:ok, _} =
      seed_identifier(
        actor,
        shared.uid,
        :integration_id,
        "proxmox:v2:farm#{seed}:vm:114",
        "shared-src"
      )

    {:ok, _} =
      seed_identifier(
        actor,
        shared.uid,
        :integration_id,
        "proxmox:v2:tonka#{seed}:vm:114",
        "shared-src"
      )

    {:ok, _} =
      seed_identifier(
        actor,
        shared.uid,
        :mac,
        "CC" <> String.pad_leading(Integer.to_string(seed, 16), 10, "0"),
        "shared-src"
      )

    report = ProxmoxUnfuse.run(:dry_run, [], nil, actor)

    assert report.skipped["ambiguous_mac_attribution"] >= 1
  end

  defp create_device(actor, attrs) do
    seed = System.unique_integer([:positive])

    Device
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          uid: "sr:unfuse-#{seed}",
          hostname: "unfuse-#{seed}",
          ip: "10.96.#{:rand.uniform(250)}.#{:rand.uniform(250)}"
        },
        attrs
      )
    )
    |> Ash.create(actor: actor)
  end

  defp seed_identifier(actor, device_uid, type, value, source_id) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:upsert, %{
      device_id: device_uid,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      confidence: :strong,
      source: "proxmox_unfuse_test",
      metadata: %{"sync_service_id" => source_id, "integration_type" => "proxmox"}
    })
    |> Ash.create(actor: actor)
  end
end
